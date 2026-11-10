#!/usr/bin/env python3
"""把會議記錄 minutes.md 轉成 Tailwind 版型的 PDF（黑白極簡）。

用法：
    python3 md2pdf.py minutes.md [-o minutes.pdf] [--html] [--cdn]

  --html  同時留下 minutes.html，可以直接用瀏覽器打開預覽版型
  --cdn   改用 Tailwind 官方 CDN 即時編譯（需要網路）。只有在你改了 Tailwind class、
          而 assets/tailwind.css 裡沒有那些 class 時才需要

只用 Python 標準函式庫；用 Chrome / Edge / Brave / Chromium 的無頭模式列印成 PDF。
版型會依 template.md 的固定章節（摘要、討論重點、決議事項、待辦事項、待確認）排版，
其他章節用通用樣式。
"""
import argparse
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
TAILWIND_CSS = SKILL_DIR / "assets" / "tailwind.css"
PRINT_CSS = SKILL_DIR / "assets" / "print.css"
TAILWIND_CDN = "https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"

CHROME_CANDIDATES = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "microsoft-edge",
]

NA_WORDS = {"未指定", "未記錄", "未提及", "無", "—", "-", ""}
LIST_RE = re.compile(r"^(\s*)([-*+]|\d+[.)])\s+(.*)$")
HR_RE = re.compile(r"^(-{3,}|\*{3,}|_{3,})$")


# ───────────────────────── Markdown 解析 ─────────────────────────
def inline(text: str) -> str:
    codes = []

    def keep(m):
        codes.append(html.escape(m.group(1)))
        return f"\x00{len(codes) - 1}\x00"

    text = re.sub(r"`([^`]+)`", keep, text)
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r'<strong class="font-semibold text-black">\1</strong>', text)
    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", r'<a class="underline underline-offset-2" href="\2">\1</a>', text)
    text = re.sub(r"\x00(\d+)\x00",
                  lambda m: f'<code class="rounded bg-neutral-100 px-1 py-0.5 font-mono text-[0.9em]">{codes[int(m.group(1))]}</code>',
                  text)
    return text


def join_lines(parts):
    """中文行直接接起來，英文行之間補空白。"""
    out = ""
    for p in parts:
        if out and not (ord(out[-1]) > 0x2E80 or ord(p[0]) > 0x2E80):
            out += " "
        out += p
    return out


def split_row(line):
    line = line.strip().strip("|")
    return [c.strip() for c in line.split("|")]


def parse_blocks(lines):
    """把一段 Markdown 切成 block：('p', text) ('list', [(indent, ordered, text)]) ('table', rows) ('h3', text) ('quote', text) ('hr',)"""
    blocks, i = [], 0
    while i < len(lines):
        s = lines[i].strip()
        if not s:
            i += 1
        elif s.startswith("### "):
            blocks.append(("h3", s[4:].strip()))
            i += 1
        elif HR_RE.fullmatch(s):
            blocks.append(("hr",))
            i += 1
        elif s.startswith("|"):
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append(split_row(lines[i]))
                i += 1
            rows = [r for r in rows if not all(re.fullmatch(r":?-{2,}:?", c) for c in r)]
            blocks.append(("table", rows))
        elif LIST_RE.match(lines[i]):
            items = []
            while i < len(lines):
                m = LIST_RE.match(lines[i])
                if m:
                    items.append([len(m.group(1).expandtabs(4)), m.group(2)[0].isdigit(), m.group(3).strip()])
                elif lines[i].strip() and lines[i][:1] in " \t" and items:
                    items[-1][2] = join_lines([items[-1][2], lines[i].strip()])
                else:
                    break
                i += 1
            blocks.append(("list", items))
        elif s.startswith(">"):
            q = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                q.append(lines[i].strip()[1:].strip())
                i += 1
            blocks.append(("quote", join_lines(q)))
        else:
            para = []
            while i < len(lines):
                t = lines[i].strip()
                if not t or t.startswith(("#", "|", ">")) or LIST_RE.match(lines[i]) or HR_RE.fullmatch(t):
                    break
                para.append(t)
                i += 1
            blocks.append(("p", join_lines(para)))
    return blocks


def parse_doc(md):
    lines = md.replace("\r\n", "\n").split("\n")
    title, meta, intro, sections, cur = "", [], [], [], None
    for line in lines:
        s = line.strip()
        if s.startswith("# ") and not title:
            title = s[2:].strip()
        elif s.startswith("## "):
            cur = {"title": s[3:].strip(), "lines": []}
            sections.append(cur)
        elif cur is not None:
            cur["lines"].append(line)
        else:
            intro.append(line)
    # 標題下方第一個表格當作會議資訊
    rest = []
    for b in parse_blocks(intro):
        if b[0] == "table" and not meta:
            rows = b[1]
            if rows and rows[0][:2] in (["項目", "內容"], ["欄位", "內容"]):
                rows = rows[1:]
            meta = [(r[0], r[1] if len(r) > 1 else "") for r in rows]
        else:
            rest.append(b)
    for sec in sections:
        sec["blocks"] = parse_blocks(sec.pop("lines"))
    return title, meta, rest, sections


# ───────────────────────── 元件 ─────────────────────────
ICONS = json.loads((SKILL_DIR / "assets" / "icons.json").read_text(encoding="utf-8"))


def icon(name, cls="size-4"):
    """Solar Bold Duotone 圖示（currentColor，雙色調靠 opacity）。"""
    svg = ICONS.get(name) or ICONS["bookmark"]
    return svg.replace("<svg ", f'<svg class="{cls} shrink-0" aria-hidden="true" ', 1)


# ───────────────────────── Badge ─────────────────────────
BADGE_VARIANTS = {
    "solid":   "bg-black text-white",
    "soft":    "bg-neutral-100 text-neutral-700",
    "outline": "border border-neutral-300 bg-white text-neutral-900",
    "dashed":  "border border-dashed border-neutral-300 text-neutral-400",
    "muted":   "bg-neutral-50 text-neutral-500",
}
BADGE_SIZES = {
    "md": "gap-1.5 px-3.5 py-1 text-[12.5px]",
    "sm": "gap-1 px-2.5 py-0.5 text-[11.5px]",
}


def badge(text, variant="soft", icon_name=None, size="md", count=None):
    ic = ""  # 圖示只用在會議資訊列，badge 不放圖示
    num = f'<b class="font-semibold tabular-nums">{count}</b>' if count is not None else ""
    return (f'<span class="inline-flex items-center whitespace-nowrap rounded-full font-medium '
            f'{BADGE_VARIANTS[variant]} {BADGE_SIZES[size]}">{ic}{num}<span>{text}</span></span>')


# ───────────────────────── 元件 ─────────────────────────
def task_text(text):
    m = re.match(r"\[( |x|X)\]\s+(.*)", text)
    return (m.group(2), m.group(1).lower() == "x") if m else (text, None)


def checkbox(done):
    box = "bg-black border-black" if done else "border-neutral-400 bg-white"
    return f'<span class="mt-[0.32em] size-3.5 shrink-0 rounded-[4px] border-[1.5px] {box}"></span>'


def render_list(items, kind="bullet"):
    if not items:
        return ""
    base = items[0][0]
    dot = "bg-black"
    text_cls = "text-neutral-800" if kind == "bullet" else "text-neutral-500"
    out = [f'<ul class="space-y-2 {text_cls}">']
    open_sub = False
    for indent, ordered, text in items:
        text, done = task_text(text)
        if indent > base and not open_sub:
            out.append('<ul class="mt-1.5 space-y-1 pl-4 text-neutral-500">')
            open_sub = True
        elif indent <= base and open_sub:
            out.append("</ul>")
            open_sub = False
        marker = checkbox(done) if done is not None else f'<span class="mt-[0.66em] size-1.5 shrink-0 rounded-full {dot}"></span>'
        out.append(f'<li class="flex gap-3 break-inside-avoid">{marker}<span>{inline(text)}</span></li>')
    if open_sub:
        out.append("</ul>")
    out.append("</ul>")
    return "".join(out)


def render_numbered(items):
    out = ['<ol class="space-y-3">']
    n = 0
    for indent, ordered, text in items:
        if indent > items[0][0]:
            out.append(f'<li class="pl-11 text-neutral-500 break-inside-avoid">{inline(text)}</li>')
            continue
        n += 1
        out.append(
            '<li class="flex items-start gap-4 break-inside-avoid rounded-xl border border-neutral-200 px-6 py-4">'
            f'<span class="flex size-7 shrink-0 items-center justify-center rounded-full bg-black text-[13px] font-semibold tabular-nums text-white">{n}</span>'
            f'<span class="pt-[2px] text-[15px] text-neutral-900">{inline(text)}</span></li>'
        )
    out.append("</ol>")
    return "".join(out)


def is_na(c):
    return c.strip() in NA_WORDS


def cell(c):
    return f'<span class="text-neutral-400">{inline(c) if c.strip() else "未指定"}</span>' if is_na(c) else inline(c)


def render_table(rows, todo=False):
    if not rows:
        return ""
    head, body = rows[0], rows[1:]
    th = "".join(
        f'<th class="px-6 py-3.5 text-left text-[11px] font-semibold uppercase tracking-[0.14em] text-neutral-500{" w-full" if j == 0 else " whitespace-nowrap"}">{inline(h)}</th>'
        for j, h in enumerate(head)
    )
    trs = []
    for r in body:
        r = (r + [""] * len(head))[:len(head)]
        tds = []
        for j, c in enumerate(r):
            if j == 0 and todo:
                text, done = task_text(c)
                tds.append(f'<td class="px-6 py-4 align-top"><div class="flex gap-3">{checkbox(done)}<span class="text-neutral-900">{inline(text)}</span></div></td>')
            elif todo and j == 1:
                tds.append('<td class="px-6 py-4 align-top whitespace-nowrap">'
                           + (badge("未指定", "dashed", "user-rounded", "sm") if is_na(c) else badge(inline(c), "outline", "user-rounded", "sm"))
                           + "</td>")
            elif todo and j == 2:
                tds.append('<td class="px-6 py-4 align-top whitespace-nowrap">'
                           + (badge("未指定", "dashed", "calendar", "sm") if is_na(c) else badge(inline(c), "soft", "calendar", "sm"))
                           + "</td>")
            else:
                cls = " whitespace-nowrap" if j else " text-neutral-900"
                tds.append(f'<td class="px-6 py-4 align-top{cls}">{cell(c)}</td>')
        trs.append(f'<tr class="break-inside-avoid border-t border-neutral-200">{"".join(tds)}</tr>')
    return (
        '<div class="overflow-hidden rounded-2xl border border-neutral-200">'
        f'<table class="w-full border-collapse text-[14px]"><thead class="bg-neutral-50"><tr>{th}</tr></thead>'
        f'<tbody>{"".join(trs)}</tbody></table></div>'
    )


def render_generic(blocks, muted=False):
    out = []
    for b in blocks:
        if b[0] == "p":
            out.append(f'<p class="{"text-neutral-500" if muted else "text-neutral-800"}">{inline(b[1])}</p>')
        elif b[0] == "h3":
            out.append(f'<h3 class="pt-2 text-[16px] font-semibold text-black">{inline(b[1])}</h3>')
        elif b[0] == "list":
            out.append(render_numbered(b[1]) if b[1][0][1] and not muted else render_list(b[1], "muted" if muted else "bullet"))
        elif b[0] == "table":
            out.append(render_table(b[1]))
        elif b[0] == "quote":
            out.append(f'<blockquote class="border-l-2 border-black pl-4 text-neutral-600">{inline(b[1])}</blockquote>')
        elif b[0] == "hr":
            out.append('<hr class="border-neutral-200">')
    return f'<div class="space-y-3">{"".join(out)}</div>'


# ───────────────────────── 章節 ─────────────────────────
SECTION_ICONS = {
    "摘要": "document-text",
    "討論重點": "chat-round-dots",
    "決議事項": "check-circle",
    "待辦事項": "checklist-minimalistic",
    "待確認": "question-circle",
}


def section_shell(num, title, body, aside=""):
    return (
        '<section class="mt-12">'
        '<div class="mb-6 flex items-baseline gap-4 break-after-avoid">'
        f'<span class="text-[30px] font-bold leading-none tracking-tight tabular-nums text-neutral-300">{num:02d}</span>'
        f'<h2 class="flex-1 text-[30px] font-bold leading-none tracking-tight text-black">{inline(title)}</h2>'
        f'<span class="mb-[2px]">{aside}</span>'
        f'</div>{body}</section>'
    )


def list_count(blocks, top_only=True):
    n = 0
    for b in blocks:
        if b[0] == "list":
            n += len([i for i in b[1] if not top_only or i[0] == b[1][0][0]])
    return n


def sec_summary(num, sec):
    paras = "".join(f'<p>{inline(b[1])}</p>' for b in sec["blocks"] if b[0] == "p")
    others = [b for b in sec["blocks"] if b[0] != "p"]
    body = (
        '<div class="break-inside-avoid rounded-2xl bg-black px-10 py-9 text-[15.5px] leading-[1.9] text-white">'
        f'<div class="space-y-3">{paras}</div></div>'
    )
    if others:
        body += f'<div class="mt-4">{render_generic(others)}</div>'
    return section_shell(num, sec["title"], body, badge("TL;DR", "soft", size="sm"))


def sec_topics(num, sec):
    topics, cur = [], None
    for b in sec["blocks"]:
        if b[0] == "h3":
            cur = {"title": b[1], "blocks": []}
            topics.append(cur)
        else:
            if cur is None:
                cur = {"title": "", "blocks": []}
                topics.append(cur)
            cur["blocks"].append(b)
    cards = []
    for k, t in enumerate(topics, 1):
        head = (
            '<div class="mb-4 flex items-baseline gap-3">'
            f'<span class="text-[19px] font-bold leading-tight tabular-nums text-neutral-300">{num}-{k}</span>'
            f'<h3 class="flex-1 text-[19px] font-bold leading-tight text-black">{inline(t["title"])}</h3></div>'
        ) if t["title"] else ""
        cards.append(
            '<div class="break-inside-avoid rounded-2xl border border-neutral-200 px-8 py-6">'
            f'{head}{render_generic(t["blocks"])}</div>'
        )
    aside = badge("個主題", "outline", "chat-round-dots", "sm", count=len(topics))
    return section_shell(num, sec["title"], f'<div class="space-y-3">{"".join(cards)}</div>', aside)


def sec_decisions(num, sec):
    items = [it for b in sec["blocks"] if b[0] == "list" for it in b[1]]
    body = render_numbered(items) if items else render_generic(sec["blocks"])
    rest = [b for b in sec["blocks"] if b[0] != "list"]
    if items and rest:
        body += f'<div class="mt-3">{render_generic(rest)}</div>'
    aside = badge("項", "solid", "check-circle", "sm", count=list_count(sec["blocks"])) if items else ""
    return section_shell(num, sec["title"], body, aside)


def todo_rows(sec):
    return [r for b in sec["blocks"] if b[0] == "table" for r in b[1][1:]]


def sec_todos(num, sec):
    tables = [b for b in sec["blocks"] if b[0] == "table"]
    if tables:
        body = render_table(tables[0][1], todo=True)
        rest = [b for b in sec["blocks"] if b is not tables[0]]
        if rest:
            body += f'<div class="mt-3">{render_generic(rest)}</div>'
        rows = todo_rows(sec)
        unassigned = sum(1 for r in rows if len(r) < 2 or is_na(r[1]))
        aside = badge("項", "soft", "checklist-minimalistic", "sm", count=len(rows))
        if unassigned:
            aside += " " + badge("未指派", "dashed", "user-rounded", "sm", count=unassigned)
    else:
        body = render_generic(sec["blocks"])
        aside = ""
    return section_shell(num, sec["title"], body, f'<span class="flex gap-1.5">{aside}</span>')


def pending_items(sec):
    return [i for b in sec["blocks"] if b[0] == "list" for i in b[1] if not is_na(i[2])]


def sec_pending(num, sec):
    body = (
        '<div class="break-inside-avoid rounded-2xl border border-dashed border-neutral-300 px-8 py-6 text-[14px]">'
        f'{render_generic(sec["blocks"], muted=True)}</div>'
    )
    n = len(pending_items(sec))
    return section_shell(num, sec["title"], body, badge("處", "dashed", "danger-circle", "sm", count=n) if n else "")


SECTION_RENDERERS = {
    "摘要": sec_summary,
    "討論重點": sec_topics,
    "決議事項": sec_decisions,
    "待辦事項": sec_todos,
    "待確認": sec_pending,
}


# ───────────────────────── 頁面 ─────────────────────────
META_ICONS = {"日期": "calendar", "時間": "calendar", "時長": "clock-circle",
              "與會者": "users-group-rounded", "地點": "flag", "主持人": "user-rounded"}
META_SKIP = {"記錄方式"}


def render_meta(meta):
    items = []
    for k, v in meta:
        if k in META_SKIP or not v.strip():
            continue
        if k in META_ICONS:
            label = ""
        else:
            label = f'<span class="text-neutral-400">{inline(k)}</span>'
        items.append(
            f'<span class="inline-flex items-center gap-2 text-neutral-900">'
            f'<span class="text-black">{icon(META_ICONS.get(k, "bookmark"), "size-[18px]")}</span>{label}{cell(v)}</span>'
        )
    if not items:
        return ""
    sep = '<span class="h-4 w-px bg-neutral-300"></span>'
    return f'<div class="mt-6 flex flex-wrap items-center gap-x-4 gap-y-2 text-[14.5px]">{sep.join(items)}</div>'


def stat_badges(sections):
    out = []
    for sec in sections:
        t = sec["title"]
        if t == "討論重點":
            n = sum(1 for b in sec["blocks"] if b[0] == "h3")
            n and out.append(badge("個主題", "outline", "chat-round-dots", count=n))
        elif t == "決議事項":
            out.append(badge("項決議", "solid", "check-circle", count=list_count(sec["blocks"])))
        elif t == "待辦事項":
            out.append(badge("項待辦", "soft", "checklist-minimalistic", count=len(todo_rows(sec))))
        elif t == "待確認":
            n = len(pending_items(sec))
            n and out.append(badge("處待確認", "dashed", "question-circle", count=n))
    return "".join(out)


def build_html(md, use_cdn=False):
    title, meta, intro, sections = parse_doc(md)
    date = next((v for k, v in meta if k == "日期"), "")

    parts = []
    for n, sec in enumerate(sections, 1):
        fn = SECTION_RENDERERS.get(sec["title"])
        parts.append(fn(n, sec) if fn else section_shell(n, sec["title"], render_generic(sec["blocks"])))

    header = (
        '<header class="cover">'
        '<div class="flex items-center gap-2.5">'
        '<span class="size-3 rounded-[3px] bg-black"></span>'
        '<span class="text-[13px] font-semibold tracking-[0.2em] text-black">會議記錄</span></div>'
        f'<h1 class="mt-4 text-[42px] font-bold leading-[1.15] tracking-tight text-black">{inline(title)}</h1>'
        f'{render_meta(meta)}'
        f'<div class="mt-5 flex flex-wrap gap-2">{stat_badges(sections)}</div>'
        f'{render_generic(intro) if intro else ""}'
        '</header>'
    )

    print_css = PRINT_CSS.read_text(encoding="utf-8")
    if use_cdn:
        styles = f'<script src="{TAILWIND_CDN}"></script><style type="text/tailwindcss">@theme {{ --font-sans: {FONT_STACK}; }}</style>'
    else:
        styles = f"<style>{TAILWIND_CSS.read_text(encoding='utf-8')}</style>"

    return (
        '<!doctype html><html lang="zh-Hant-TW"><head><meta charset="utf-8">'
        f'<meta name="viewport" content="width=device-width, initial-scale=1"><title>{html.escape(title)}</title>'
        f'{styles}<style>{print_css}</style></head>'
        '<body class="bg-white font-sans text-[14px] leading-[1.8] text-neutral-800 antialiased">'
        f'<main class="page">{header}{"".join(parts)}</main></body></html>'
    )


FONT_STACK = '-apple-system, "SF Pro Text", "Helvetica Neue", "PingFang TC", "Noto Sans CJK TC", "Noto Sans TC", sans-serif'


def css_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


# ───────────────────────── 列印 ─────────────────────────
def find_chrome():
    if os.environ.get("CHROME"):
        return os.environ["CHROME"]
    for c in CHROME_CANDIDATES:
        if os.path.isabs(c) and os.path.exists(c):
            return c
        if shutil.which(c):
            return shutil.which(c)
    return None


def print_pdf(html_path, pdf_path, wait_ms=0):
    chrome = find_chrome()
    if not chrome:
        sys.exit("找不到 Chrome / Edge / Brave / Chromium。請安裝其中一個，或用 CHROME=執行檔路徑 指定。")
    pdf_path.unlink(missing_ok=True)
    cmd = [chrome, "--headless", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
           "--no-pdf-header-footer", "--disable-dev-shm-usage",
           "--disable-background-networking", "--disable-component-update"]
    if wait_ms:
        cmd.append(f"--virtual-time-budget={wait_ms}")
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        cmd.append("--no-sandbox")
    cmd += [f"--print-to-pdf={pdf_path}", html_path.as_uri()]

    with tempfile.TemporaryFile() as log:
        proc = subprocess.Popen(cmd, stdout=log, stderr=log)
        # 有些環境 Chrome 印完不會自己結束：看到 PDF 寫完、大小穩定就收工
        deadline, last = time.time() + 90, -1
        while time.time() < deadline and proc.poll() is None:
            size = pdf_path.stat().st_size if pdf_path.exists() else 0
            if size and size == last:
                break
            last = size
            time.sleep(1)
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(5)
            except subprocess.TimeoutExpired:
                proc.kill()
        log.seek(0)
        err = log.read().decode("utf-8", "replace")
    if not pdf_path.exists() or pdf_path.stat().st_size == 0:
        sys.exit(f"PDF 產生失敗：\n{err[-2000:]}")


def main():
    ap = argparse.ArgumentParser(description="會議記錄 Markdown → PDF（Tailwind 版型）")
    ap.add_argument("markdown")
    ap.add_argument("-o", "--output")
    ap.add_argument("--html", action="store_true", help="同時保留 HTML 檔")
    ap.add_argument("--cdn", action="store_true", help="用 Tailwind CDN 即時編譯（需要網路）")
    a = ap.parse_args()

    md_path = Path(a.markdown).expanduser().resolve()
    pdf_path = Path(a.output).expanduser().resolve() if a.output else md_path.with_suffix(".pdf")
    doc = build_html(md_path.read_text(encoding="utf-8"), use_cdn=a.cdn)
    wait = 4000 if a.cdn else 0

    if a.html:
        html_path = md_path.with_suffix(".html")
        html_path.write_text(doc, encoding="utf-8")
        print_pdf(html_path, pdf_path, wait)
    else:
        with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False, encoding="utf-8") as f:
            f.write(doc)
            tmp = Path(f.name)
        try:
            print_pdf(tmp, pdf_path, wait)
        finally:
            tmp.unlink(missing_ok=True)
    print(f"完成：{pdf_path}")


if __name__ == "__main__":
    main()
