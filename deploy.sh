#!/bin/bash
set -e

cd /home/vaultai

echo "=== 1. Останавливаем старого бота ==="
pkill -f gemini_bridge_cdp.py || true
sleep 1

echo "=== 2. Создаём gemini_dom_probe.py ==="
cat > gemini_dom_probe.py << 'PYEOF'
#!/usr/bin/env python3
"""
Зонд для исследования DOM Gemini Notebook.
Подключается к запущенному Chrome CDP, делает скриншот
нижней части страницы и ищет элементы для загрузки файлов.
"""

import asyncio
import json
import os
import sys

from playwright.async_api import async_playwright

CDP_URL = "http://127.0.0.1:9222"
NOTEBOOK_URL = "https://gemini.google.com/notebook/a09faa92-91a4-4834-be93-701afa3f7863"
OUTPUT_DIR = "/home/vaultai/_черновики_hermes/входящие_gemini_cdp"


async def probe():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    async with async_playwright() as p:
        print("[*] Подключаемся к Chrome CDP...")
        browser = await p.chromium.connect_over_cdp(CDP_URL)
        context = browser.contexts[0] if browser.contexts else await browser.new_context()
        page = context.pages[0] if context.pages else await context.new_page()

        print(f"[*] Текущий URL: {page.url}")

        if "notebook/a09faa92" not in page.url:
            print(f"[*] Переходим в блокнот {NOTEBOOK_URL} ...")
            await page.goto(NOTEBOOK_URL, wait_until="networkidle", timeout=120_000)
            await asyncio.sleep(5)

        full_shot = os.path.join(OUTPUT_DIR, "probe_full.png")
        await page.screenshot(path=full_shot, full_page=True)
        print(f"[+] Скриншот всей страницы: {full_shot}")

        viewport_shot = os.path.join(OUTPUT_DIR, "probe_viewport_bottom.png")
        await page.screenshot(path=viewport_shot)
        print(f"[+] Скриншот viewport: {viewport_shot}")

        print("\n[*] Исследуем DOM вокруг поля ввода...")

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
                print(f"    Найдено {len(els)} элементов по селектору: {sel}")
                input_el = els[-1]
            else:
                print(f"    Не найдено: {sel}")

        if input_el:
            tag = await input_el.evaluate("el => el.tagName")
            print(f"\n[+] Используем поле ввода: <{tag}>")
            parent_html = await input_el.evaluate("""
                el => {
                    const p = el.closest('div[class*="input"]')
                           || el.closest('div[class*="composer"]')
                           || el.closest('div[class*="footer"]')
                           || el.closest('div[class*="bottom"]')
                           || el.parentElement;
                    return p ? p.outerHTML.substring(0, 4000) : 'no parent';
                }
            """)
            print(f"\n--- HTML родителя (обрезано) ---\n{parent_html}\n---")

        print("\n[*] Ищем кнопки вложений...")
        attach_selectors = [
            'button[aria-label*="attach" i]',
            'button[aria-label*="upload" i]',
            'button[aria-label*="file" i]',
            'button[aria-label*="image" i]',
            'button[aria-label*="add" i]',
            'button[title*="attach" i]',
            'button[title*="upload" i]',
            'svg[name*="attach" i]',
            'svg[name*="upload" i]',
            'div[role="button"][aria-label*="attach" i]',
            'div[role="button"][aria-label*="upload" i]',
            'button[class*="attach" i]',
            'button[class*="upload" i]',
            'button[class*="add" i]',
            'button[class*="plus" i]',
            'icon-button[class*="attach" i]',
            'mio-icon-button[class*="attach" i]',
        ]

        found_buttons = []
        for sel in attach_selectors:
            els = await page.query_selector_all(sel)
            for i, el in enumerate(els):
                aria = await el.get_attribute("aria-label") or ""
                title = await el.get_attribute("title") or ""
                cls = await el.get_attribute("class") or ""
                found_buttons.append({"sel": sel, "idx": i, "aria": aria, "title": title, "class": cls[:100]})
                print(f"    Найдена кнопка: sel={sel} idx={i} aria='{aria}' title='{title}' class='{cls[:60]}...'")

        if not found_buttons:
            print("    Кнопки вложений по стандартным селекторам НЕ найдены.")
            all_btns = await page.query_selector_all('button, [role="button"], icon-button, mio-icon-button')
            print(f"    Всего кнопок на странице: {len(all_btns)}")
            for i, btn in enumerate(all_btns[-20:]):
                aria = await btn.get_attribute("aria-label") or ""
                txt = await btn.inner_text()
                if aria or txt:
                    print(f"      btn[{i}] aria='{aria}' text='{txt[:40]}'")

        print("\n[*] Ищем input[type=file]...")
        file_inputs = await page.query_selector_all('input[type="file"]')
        print(f"    Найдено input[type=file]: {len(file_inputs)}")
        for i, inp in enumerate(file_inputs):
            cls = await inp.get_attribute("class") or ""
            style = await inp.get_attribute("style") or ""
            print(f"      input[{i}] class='{cls}' style='{style[:100]}'")

        if found_buttons:
            btn_info = found_buttons[0]
            sel = btn_info["sel"]
            idx = btn_info["idx"]
            print(f"\n[*] Кликаем на кнопку: {sel}[{idx}] ...")
            try:
                await page.click(f"{sel} >> nth={idx}", timeout=5000)
                print("    Клик выполнен.")
                await asyncio.sleep(2)

                file_inputs2 = await page.query_selector_all('input[type="file"]')
                print(f"    После клика input[type=file]: {len(file_inputs2)}")
                for i, inp in enumerate(file_inputs2):
                    cls = await inp.get_attribute("class") or ""
                    style = await inp.get_attribute("style") or ""
                    print(f"      input[{i}] class='{cls}' style='{style[:100]}'")

                click_shot = os.path.join(OUTPUT_DIR, "probe_after_click.png")
                await page.screenshot(path=click_shot)
                print(f"    Скриншот после клика: {click_shot}")
            except Exception as e:
                print(f"    Ошибка клика: {e}")

        print("\n[*] Извлекаем HTML нижней части страницы...")
        bottom_html = await page.evaluate("""
            () => {
                const allDivs = document.querySelectorAll('div');
                const last = Array.from(allDivs).slice(-5);
                return last.map(d => d.outerHTML.substring(0, 2000)).join('\\n\\n---NEXT---\\n\\n');
            }
        """)
        html_path = os.path.join(OUTPUT_DIR, "probe_bottom_html.txt")
        with open(html_path, "w", encoding="utf-8") as f:
            f.write(bottom_html)
        print(f"    HTML сохранён: {html_path}")

        print("\n[+] Зонд завершён. Проверьте файлы в папке:")
        print(f"    {OUTPUT_DIR}")
        await browser.close()


if __name__ == "__main__":
    asyncio.run(probe())
PYEOF

echo "=== 3. Создаём gemini_bridge_cdp_v2.py ==="
cat > gemini_bridge_cdp_v2.py << 'PYEOF'
#!/usr/bin/env python3
"""
Gemini Pro <-> Telegram Bridge (CDP / Playwright). Version 2.
No fragile goto. Supports file upload from Telegram.
"""

import asyncio
import base64
import json
import logging
import os
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Optional, List

import httpx
from playwright.async_api import async_playwright, Page, BrowserContext
from telegram import Update, InputMediaPhoto
from telegram.ext import (
    ApplicationBuilder,
    CommandHandler,
    MessageHandler,
    filters,
    ContextTypes,
)

# ─── Configuration ───────────────────────────────────────────────────────────
TELEGRAM_TOKEN = "562163923:AAHAfBsKIR6V4K_CWv2yq8xopXFmJNTQV8E"
CDP_URL = "http://127.0.0.1:9222"
NOTEBOOK_URL = "https://gemini.google.com/notebook/a09faa92-91a4-4834-be93-701afa3f7863"
DOWNLOAD_DIR = Path("/home/vaultai/_черновики_hermes/входящие_gemini_cdp")
LOG_PATH = Path("/home/vaultai/_черновики_hermes/gemini_cdp_v2.log")

DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
LOG_PATH.parent.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(message)s",
    handlers=[
        logging.FileHandler(LOG_PATH, encoding="utf-8"),
        logging.StreamHandler(sys.stdout),
    ],
)
logger = logging.getLogger("gemini_bridge")

# ─── Globals ─────────────────────────────────────────────────────────────────
_page: Optional[Page] = None
_context: Optional[BrowserContext] = None
_browser = None
_playwright = None
_init_done = False


# ─── Playwright helpers ──────────────────────────────────────────────────────

async def _get_page() -> Page:
    global _page, _context, _browser, _playwright, _init_done
    if _page and not _page.is_closed():
        return _page

    logger.info("[*] Подключаемся к Chrome CDP...")
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
        logger.info("[+] Уже в блокноте.")
        return
    logger.info(f"[*] Переходим в блокнот {NOTEBOOK_URL} ...")
    await page.goto(NOTEBOOK_URL, wait_until="networkidle", timeout=120_000)
    await asyncio.sleep(5)
    logger.info(f"[+] Блокнот загружен. URL: {page.url}")


async def _ensure_alive():
    page = await _get_page()
    try:
        await page.evaluate("() => document.title")
    except Exception as e:
        logger.warning(f"[!] Страница мертва: {e}. Переподключаемся...")
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


# ─── File attachment logic ───────────────────────────────────────────────────

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
            logger.info(f"[+] Кнопка вложения найдена: {sel} (aria='{aria}')")
            return btn

    logger.warning("[!] Кнопка вложения по стандартным селекторам не найдена. Пробуем эвристику...")
    all_btns = await page.query_selector_all('button, [role="button"], mio-icon-button, icon-button')
    for btn in all_btns[-10:]:
        txt = await btn.inner_text()
        aria = await btn.get_attribute("aria-label") or ""
        if any(x in (aria + txt).lower() for x in ["send", "submit", "mic", "voice", "record"]):
            continue
        has_svg = await btn.query_selector("svg") is not None
        if has_svg and (aria or txt):
            logger.info(f"[+] Найдена кнопка-кандидат: aria='{aria}' text='{txt[:30]}'")
            return btn
    return None


async def _attach_files(page: Page, file_paths: List[Path]) -> bool:
    if not file_paths:
        return True

    btn = await _find_attachment_button(page)
    if not btn:
        logger.error("[!] Не удалось найти кнопку вложения.")
        return False

    try:
        await btn.click(timeout=5000)
        logger.info("[+] Клик по кнопке вложения выполнен.")
        await asyncio.sleep(1.5)
    except Exception as e:
        logger.error(f"[!] Ошибка клика по кнопке вложения: {e}")
        return False

    file_input = await page.query_selector('input[type="file"]')
    if file_input:
        logger.info(f"[+] Найден input[type=file], загружаем {len(file_paths)} файл(ов)...")
        str_paths = [str(p.resolve()) for p in file_paths]
        try:
            await file_input.set_input_files(str_paths)
            logger.info("[+] Файлы установлены в input.")
            await asyncio.sleep(2)
            return True
        except Exception as e:
            logger.error(f"[!] Ошибка set_input_files: {e}")
            return False

    logger.warning("[!] input[type=file] не найден. Пробуем CDP fallback...")
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
            logger.info("[+] Файлы загружены через временный input.")
            return True
    except Exception as e:
        logger.error(f"[!] CDP fallback не сработал: {e}")

    return False


# ─── Gemini interaction ──────────────────────────────────────────────────────

async def _send_to_gemini(text: str, file_paths: List[Path] = None) -> str:
    page = await _ensure_alive()
    file_paths = file_paths or []

    if file_paths:
        ok = await _attach_files(page, file_paths)
        if not ok:
            logger.warning("[!] Не удалось прикрепить файлы, отправляем только текст.")

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
        raise RuntimeError("Не найдено поле ввода Gemini")

    tag = await input_el.evaluate("el => el.tagName")
    if tag.lower() == "textarea":
        await input_el.fill("")
        await input_el.fill(text)
    else:
        await input_el.click()
        await input_el.evaluate("el => el.innerText = ''")
        await input_el.type(text)

    logger.info(f"[+] Текст введён ({len(text)} символов)")
    await asyncio.sleep(0.5)

    await input_el.press("Enter")
    logger.info("[+] Enter нажат, ждём ответ...")

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
        answer = last_answer or "(пустой ответ)"

    logger.info(f"[+] Ответ получен ({len(answer)} символов)")
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

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(
        "Привет! Я Gemini Pro Bridge (v2).\n"
        "Отправь текст или фото — я передам в Gemini и верну ответ."
    )


async def handle_text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_text = update.message.text or ""
    chat_id = update.effective_chat.id
    logger.info(f"[TG] Текст от {chat_id}: {user_text[:80]}...")

    try:
        answer = await _send_to_gemini(user_text)
    except Exception as e:
        logger.exception("Ошибка отправки в Gemini")
        await update.message.reply_text(f"❌ Ошибка Gemini: {e}")
        return

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
                logger.warning(f"Не удалось отправить изображение {url[:60]}: {e}")
    else:
        for chunk in [answer[i:i+3900] for i in range(0, len(answer), 3900)]:
            await update.message.reply_text(chunk)


async def handle_photo(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat_id = update.effective_chat.id
    caption = update.message.caption or ""
    logger.info(f"[TG] Фото от {chat_id} с подписью: {caption[:80]}...")

    photo = update.message.photo[-1]
    file_obj = await context.bot.get_file(photo.file_id)
    ext = ".jpg"
    local_path = DOWNLOAD_DIR / f"{chat_id}_{int(time.time())}{ext}"
    await file_obj.download_to_drive(str(local_path))
    logger.info(f"[+] Фото сохранено: {local_path}")

    try:
        answer = await _send_to_gemini(caption or "Опиши, что на изображении.", file_paths=[local_path])
    except Exception as e:
        logger.exception("Ошибка отправки фото в Gemini")
        await update.message.reply_text(f"❌ Ошибка Gemini: {e}")
        return

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
                logger.warning(f"Не удалось отправить изображение: {e}")
    else:
        for chunk in [answer[i:i+3900] for i in range(0, len(answer), 3900)]:
            await update.message.reply_text(chunk)


async def handle_document(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat_id = update.effective_chat.id
    caption = update.message.caption or ""
    doc = update.message.document
    logger.info(f"[TG] Документ от {chat_id}: {doc.file_name}")

    file_obj = await context.bot.get_file(doc.file_id)
    ext = Path(doc.file_name).suffix or ".bin"
    local_path = DOWNLOAD_DIR / f"{chat_id}_{int(time.time())}{ext}"
    await file_obj.download_to_drive(str(local_path))
    logger.info(f"[+] Документ сохранён: {local_path}")

    try:
        answer = await _send_to_gemini(caption or "Проанализируй этот файл.", file_paths=[local_path])
    except Exception as e:
        logger.exception("Ошибка отправки документа в Gemini")
        await update.message.reply_text(f"❌ Ошибка Gemini: {e}")
        return

    for chunk in [answer[i:i+3900] for i in range(0, len(answer), 3900)]:
        await update.message.reply_text(chunk)


# ─── Main ────────────────────────────────────────────────────────────────────

async def post_init(app):
    logger.info("[+] Бот инициализирован и готов.")


def main():
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

    logger.info("[*] Запуск polling...")
    app.run_polling()


if __name__ == "__main__":
    main()
PYEOF

echo "=== 4. Запускаем зонд ==="
python3 gemini_dom_probe.py | tee /home/vaultai/_черновики_hermes/probe_log.txt

echo ""
echo "============================================"
echo "ЗОНД ЗАВЕРШЁН."
echo "Проверьте файлы:"
echo "  /home/vaultai/_черновики_hermes/входящие_gemini_cdp/"
echo ""
echo "Далее:"
echo "  1. Пришлите мне скриншоты или лог (probe_log.txt)"
echo "  2. Я уточню селекторы если нужно"
echo "  3. Запустите нового бота:"
echo "       nohup python3 /home/vaultai/gemini_bridge_cdp_v2.py > /home/vaultai/_черновики_hermes/gemini_v2.out 2>&1 &"
echo "============================================"
