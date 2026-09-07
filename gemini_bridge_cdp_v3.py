#!/usr/bin/env python3
"""
Gemini Pro <-> Telegram Bridge (CDP / Playwright). Version 3.
- No fragile goto
- File upload support
- SQLite history (survives restarts)
- ALLOWED_CHAT_IDS gate
- httpx token leak fixed (WARNING level only)
- Auto-kills legacy API bridge on startup
"""

import asyncio
import base64
import logging
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
from typing import List, Optional

import httpx
from playwright.async_api import async_playwright, BrowserContext, Page
from telegram import Update
from telegram.ext import (
    ApplicationBuilder,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

# ─── Configuration ───────────────────────────────────────────────────────────
TELEGRAM_TOKEN = "562163923:AAHAfBsKIR6V4K_CWv2yq8xopXFmJNTQV8E"
CDP_URL = "http://127.0.0.1:9222"
NOTEBOOK_URL = "https://gemini.google.com/notebook/a09faa92-91a4-4834-be93-701afa3f7863"
DOWNLOAD_DIR = Path("/home/vaultai/_черновики_hermes/входящие_gemini_cdp")
DB_PATH = Path("/home/vaultai/_черновики_hermes/gemini_history.db")
LOG_PATH = Path("/home/vaultai/_черновики_hermes/gemini_cdp_v3.log")
ALLOWED_CHAT_IDS = {302947060}

DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
DB_PATH.parent.mkdir(parents=True, exist_ok=True)
LOG_PATH.parent.mkdir(parents=True, exist_ok=True)

# ─── Logging ─────────────────────────────────────────────────────────────────
# CRITICAL: httpx logs full URLs with token at INFO level — disable it.
logging.getLogger("httpx").setLevel(logging.WARNING)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(message)s",
    handlers=[
        logging.FileHandler(LOG_PATH, encoding="utf-8"),
        logging.StreamHandler(sys.stdout),
    ],
)
logger = logging.getLogger("gemini_bridge")

# ─── SQLite ──────────────────────────────────────────────────────────────────

def _init_db():
    with sqlite3.connect(DB_PATH, check_same_thread=False) as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_id INTEGER NOT NULL,
                role TEXT NOT NULL,
                content TEXT,
                image_path TEXT,
                timestamp REAL NOT NULL
            )
        """)
        conn.execute("""
            CREATE INDEX IF NOT EXISTS idx_history_chat_time
            ON history(chat_id, timestamp)
        """)
        conn.commit()


def _save_turn(chat_id: int, role: str, content: str, image_path: str = None):
    with sqlite3.connect(DB_PATH, check_same_thread=False) as conn:
        conn.execute(
            "INSERT INTO history (chat_id, role, content, image_path, timestamp) VALUES (?, ?, ?, ?, ?)",
            (chat_id, role, content, image_path, time.time()),
        )
        conn.commit()


def _get_recent_history(chat_id: int, limit: int = 20) -> List[dict]:
    with sqlite3.connect(DB_PATH, check_same_thread=False) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT role, content, image_path, timestamp FROM history WHERE chat_id = ? ORDER BY timestamp DESC LIMIT ?",
            (chat_id, limit),
        ).fetchall()
        return [dict(r) for r in reversed(rows)]


# ─── Kill legacy API bridge ──────────────────────────────────────────────────

def _kill_api_bridge():
    """Stop the old google.generativeai-based bridge so it doesn't fight for getUpdates."""
    try:
        # Kill 'gemini_bridge.py' but NOT 'gemini_bridge_cdp*.py'
        result = subprocess.run(
            ["pgrep", "-f", "python.*gemini_bridge.py$"],
            capture_output=True,
            text=True,
        )
        for line in result.stdout.strip().splitlines():
            pid = line.strip()
            if pid:
                logger.info(f"[*] Killing legacy API bridge PID {pid}")
                subprocess.run(["kill", "-9", pid], capture_output=True)
    except Exception as e:
        logger.warning(f"[!] Could not kill legacy bridge: {e}")


# ─── Playwright globals ──────────────────────────────────────────────────────
_page: Optional[Page] = None
_context: Optional[BrowserContext] = None
_browser = None
_playwright = None
_init_done = False


async def _get_page() -> Page:
    global _page, _context, _browser, _playwright, _init_done
    if _page and not _page.is_closed():
        return _page

    logger.info("[*] Connecting to Chrome CDP...")
    _playwright = await async_playwright().start()
    _browser = await _playwright.chromium.connect_over_cdp(CDP_URL)
    _context = _browser.contexts[0] if _browser.contexts else await _browser.new_context()
    _page = _context.pages[0] if _context.pages else await _context.new_page()

    if not _init_done:
        await _init_notebook()
        _init_done = True

    return _page


async def _init_notebook():
    page = _page
    if "notebook/a09faa92" in page.url:
        logger.info("[+] Already in notebook.")
        return
    logger.info(f"[*] Navigating to notebook...")
    await page.goto(NOTEBOOK_URL, wait_until="networkidle", timeout=120_000)
    await asyncio.sleep(5)
    logger.info(f"[+] Notebook loaded: {page.url}")


async def _ensure_alive() -> Page:
    page = await _get_page()
    try:
        await page.evaluate("() => document.title")
    except Exception as e:
        logger.warning(f"[!] Page dead: {e}. Reconnecting...")
        global _page, _browser, _playwright
        try:
            if _browser:
                await _browser.close()
        except Exception:
            pass
        try:
            if _playwright:
                await _playwright.stop()
        except Exception:
            pass
        _page = None
        _browser = None
        _playwright = None
        page = await _get_page()
    return page


# ─── File attachment ─────────────────────────────────────────────────────────

async def _find_attachment_button(page: Page):
    selectors = [
        'button[aria-label*="attach" i]',
        'button[aria-label*="upload" i]',
        'button[aria-label*="file" i]',
        'button[aria-label*="add" i]',
        'div[role="button"][aria-label*="attach" i]',
        'div[role="button"][aria-label*="upload" i]',
        'button[class*="attach" i]',
        'button[class*="upload" i]',
        'button[class*="add" i]',
        'button[class*="plus" i]',
        'mio-icon-button[aria-label*="attach" i]',
        'icon-button[aria-label*="attach" i]',
        'button[data-test-id*="attach" i]',
        'button[jsaction*="attach" i]',
    ]
    for sel in selectors:
        btn = await page.query_selector(sel)
        if btn:
            aria = await btn.get_attribute("aria-label") or ""
            logger.info(f"[+] Attach button found: {sel} (aria='{aria}')")
            return btn

    # heuristic fallback — look for icon buttons near the textarea
    logger.warning("[!] Standard attach selectors failed, trying heuristic...")
    all_btns = await page.query_selector_all('button, [role="button"], mio-icon-button, icon-button')
    for btn in all_btns[-10:]:
        txt = await btn.inner_text()
        aria = await btn.get_attribute("aria-label") or ""
        if any(x in (aria + txt).lower() for x in ["send", "submit", "mic", "voice", "record"]):
            continue
        has_svg = await btn.query_selector("svg") is not None
        if has_svg and (aria or txt):
            logger.info(f"[+] Heuristic attach candidate: aria='{aria}' text='{txt[:30]}'")
            return btn
    return None


async def _attach_files(page: Page, file_paths: List[Path]) -> bool:
    if not file_paths:
        return True

    btn = await _find_attachment_button(page)
    if not btn:
        logger.error("[!] Attach button not found.")
        return False

    try:
        await btn.click(timeout=5000)
        logger.info("[+] Attach button clicked.")
        await asyncio.sleep(1.5)
    except Exception as e:
        logger.error(f"[!] Attach click failed: {e}")
        return False

    file_input = await page.query_selector('input[type="file"]')
    if file_input:
        str_paths = [str(p.resolve()) for p in file_paths]
        try:
            await file_input.set_input_files(str_paths)
            logger.info(f"[+] Files attached via input[type=file]: {len(file_paths)}")
            await asyncio.sleep(2)
            return True
        except Exception as e:
            logger.error(f"[!] set_input_files failed: {e}")

    # fallback: create temporary file input and dispatch change event
    logger.warning("[!] No file input found, trying JS fallback...")
    try:
        await page.evaluate("""
            () => {
                let inp = document.getElementById('__temp_file_input__');
                if (!inp) {
                    inp = document.createElement('input');
                    inp.type = 'file';
                    inp.id = '__temp_file_input__';
                    inp.style.display = 'none';
                    document.body.appendChild(inp);
                }
            }
        """)
        temp_input = await page.query_selector('#__temp_file_input__')
        if temp_input:
            str_paths = [str(p.resolve()) for p in file_paths]
            await temp_input.set_input_files(str_paths)
            await temp_input.evaluate("""
                el => {
                    const event = new Event('change', { bubbles: true });
                    el.dispatchEvent(event);
                }
            """)
            logger.info("[+] Files attached via temporary input.")
            return True
    except Exception as e:
        logger.error(f"[!] JS fallback failed: {e}")

    return False


# ─── Gemini interaction ──────────────────────────────────────────────────────

async def _send_to_gemini(text: str, file_paths: List[Path] = None) -> str:
    page = await _ensure_alive()
    file_paths = file_paths or []

    if file_paths:
        ok = await _attach_files(page, file_paths)
        if not ok:
            logger.warning("[!] File attach failed, sending text only.")

    input_selectors = [
        'textarea[placeholder*="Ask"]',
        'textarea[placeholder*="Message"]',
        'textarea',
        'div[contenteditable="true"]',
        '[role="textbox"]',
    ]
    input_el = None
    for sel in input_selectors:
        els = await page.query_selector_all(sel)
        if els:
            input_el = els[-1]
            break

    if not input_el:
        raise RuntimeError("Gemini input not found")

    tag = await input_el.evaluate("el => el.tagName")
    if tag.lower() == "textarea":
        await input_el.fill("")
        await input_el.fill(text)
    else:
        await input_el.click()
        await input_el.evaluate("el => el.innerText = ''")
        await input_el.type(text)

    logger.info(f"[+] Text entered ({len(text)} chars)")
    await asyncio.sleep(0.5)
    await input_el.press("Enter")
    logger.info("[+] Enter pressed, waiting for response...")

    start = time.time()
    last_answer = ""
    stable_count = 0
    answer = ""

    while time.time() - start < 120:
        await asyncio.sleep(2)

        answer_texts = await page.evaluate("""
            () => {
                const candidates = [
                    ...document.querySelectorAll('div[data-test-id="conversation-turn"]'),
                    ...document.querySelectorAll('div[class*="response"]'),
                    ...document.querySelectorAll('div[class*="answer"]'),
                    ...document.querySelectorAll('div[class*="message-content"]'),
                    ...document.querySelectorAll('div[role="listitem"]'),
                ];
                const last = candidates[candidates.length - 1];
                if (!last) return "";
                return last.innerText || "";
            }
        """)

        if answer_texts and len(answer_texts) > len(last_answer) + 10:
            last_answer = answer_texts
            stable_count = 0
        else:
            stable_count += 1

        if stable_count >= 3 and last_answer:
            answer = last_answer
            break

        loading = await page.query_selector('[class*="loading"], [class*="spinner"], [class*="progress"]')
        if not loading and stable_count >= 2 and last_answer:
            answer = last_answer
            break

    if not answer:
        answer = last_answer or "(empty response)"

    logger.info(f"[+] Response received ({len(answer)} chars)")
    return answer


async def _extract_images_from_gemini(page: Page) -> List[str]:
    img_urls = await page.evaluate("""
        () => {
            const imgs = Array.from(document.querySelectorAll('img'));
            return imgs
                .map(i => i.src)
                .filter(src => src && (
                    src.includes('googleusercontent') ||
                    src.includes('gstatic') ||
                    src.includes('data:image') ||
                    src.includes('blob:')
                ));
        }
    """)
    seen = set()
    unique = []
    for u in img_urls:
        if u not in seen:
            seen.add(u)
            unique.append(u)
    return unique


# ─── Telegram handlers ───────────────────────────────────────────────────────

def _authorized(update: Update) -> bool:
    cid = update.effective_chat.id
    if cid not in ALLOWED_CHAT_IDS:
        logger.warning(f"[!] Unauthorized chat_id: {cid}")
        return False
    return True


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not _authorized(update):
        return
    await update.message.reply_text(
        "Gemini Pro Bridge v3 active.\nSend text or photo."
    )


async def handle_text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not _authorized(update):
        return

    chat_id = update.effective_chat.id
    user_text = update.message.text or ""
    logger.info(f"[TG] Text from {chat_id}: {user_text[:80]}...")
    _save_turn(chat_id, "user", user_text)

    try:
        answer = await _send_to_gemini(user_text)
    except Exception as e:
        logger.exception("Gemini send error")
        await update.message.reply_text(f"❌ Error: {e}")
        return

    _save_turn(chat_id, "assistant", answer)

    page = await _ensure_alive()
    img_urls = await _extract_images_from_gemini(page)

    if img_urls:
        await update.message.reply_text(answer[:3900])
        for url in img_urls[-5:]:
            try:
                if url.startswith("data:image"):
                    header, b64 = url.split(",", 1)
                    data = base64.b64decode(b64)
                    await context.bot.send_photo(chat_id=chat_id, photo=data)
                else:
                    async with httpx.AsyncClient() as client:
                        r = await client.get(url, timeout=30)
                        r.raise_for_status()
                        await context.bot.send_photo(chat_id=chat_id, photo=r.content)
            except Exception as e:
                logger.warning(f"Failed to send image: {e}")
    else:
        for chunk in [answer[i:i+3900] for i in range(0, len(answer), 3900)]:
            await update.message.reply_text(chunk)


async def handle_photo(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not _authorized(update):
        return

    chat_id = update.effective_chat.id
    caption = update.message.caption or ""
    logger.info(f"[TG] Photo from {chat_id}: {caption[:80]}...")

    photo = update.message.photo[-1]
    file_obj = await context.bot.get_file(photo.file_id)
    ext = ".jpg"
    local_path = DOWNLOAD_DIR / f"{chat_id}_{int(time.time())}{ext}"
    await file_obj.download_to_drive(str(local_path))
    logger.info(f"[+] Photo saved: {local_path}")
    _save_turn(chat_id, "user", caption or "(photo)", str(local_path))

    try:
        answer = await _send_to_gemini(caption or "Describe the image.", file_paths=[local_path])
    except Exception as e:
        logger.exception("Gemini photo send error")
        await update.message.reply_text(f"❌ Error: {e}")
        return

    _save_turn(chat_id, "assistant", answer)

    page = await _ensure_alive()
    img_urls = await _extract_images_from_gemini(page)

    if img_urls:
        await update.message.reply_text(answer[:3900])
        for url in img_urls[-5:]:
            try:
                if url.startswith("data:image"):
                    header, b64 = url.split(",", 1)
                    data = base64.b64decode(b64)
                    await context.bot.send_photo(chat_id=chat_id, photo=data)
                else:
                    async with httpx.AsyncClient() as client:
                        r = await client.get(url, timeout=30)
                        r.raise_for_status()
                        await context.bot.send_photo(chat_id=chat_id, photo=r.content)
            except Exception as e:
                logger.warning(f"Failed to send image: {e}")
    else:
        for chunk in [answer[i:i+3900] for i in range(0, len(answer), 3900)]:
            await update.message.reply_text(chunk)


async def handle_document(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not _authorized(update):
        return

    chat_id = update.effective_chat.id
    caption = update.message.caption or ""
    doc = update.message.document
    logger.info(f"[TG] Document from {chat_id}: {doc.file_name}")

    file_obj = await context.bot.get_file(doc.file_id)
    ext = Path(doc.file_name).suffix or ".bin"
    local_path = DOWNLOAD_DIR / f"{chat_id}_{int(time.time())}{ext}"
    await file_obj.download_to_drive(str(local_path))
    logger.info(f"[+] Document saved: {local_path}")
    _save_turn(chat_id, "user", caption or f"(document: {doc.file_name})", str(local_path))

    try:
        answer = await _send_to_gemini(caption or "Analyze this file.", file_paths=[local_path])
    except Exception as e:
        logger.exception("Gemini document send error")
        await update.message.reply_text(f"❌ Error: {e}")
        return

    _save_turn(chat_id, "assistant", answer)

    for chunk in [answer[i:i+3900] for i in range(0, len(answer), 3900)]:
        await update.message.reply_text(chunk)


# ─── Main ────────────────────────────────────────────────────────────────────

async def post_init(app):
    logger.info("[+] Bot initialized and ready.")


def main():
    # Cleanup
    _kill_api_bridge()
    _init_db()

    # Show recent history count
    recent = _get_recent_history(302947060, 1)
    logger.info(f"[+] DB history rows for allowed chat: {len(recent)}")

    app = (
        ApplicationBuilder()
        .token(TELEGRAM_TOKEN)
        .post_init(post_init)
        .build()
    )

    app.add_handler(CommandHandler("start", start))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_text))
    app.add_handler(MessageHandler(filters.PHOTO, handle_photo))
    app.add_handler(MessageHandler(filters.Document.ALL, handle_document))

    logger.info("[*] Starting polling...")
    app.run_polling()


if __name__ == "__main__":
    main()
