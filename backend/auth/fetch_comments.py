"""
Fetch a video's comments (read-only) using the logged-in session.

Loads the video page in a real browser and harvests TikTok's own
`/api/comment/list/` responses — no signing on our side.

Usage:  python fetch_comments.py <video_url> [count]
Prints: [{"author","nickname","avatar","text","likes"}, ...]
"""
import asyncio
import json
import os
import sys
from pathlib import Path

from playwright.async_api import async_playwright

sys.path.insert(0, str(Path(__file__).parent))
from browser import launch_browser

SESSIONID_FILE = Path(__file__).parent / "sessionid.txt"
URL = sys.argv[1]
TARGET = int(sys.argv[2]) if len(sys.argv) > 2 else 20
HEADLESS = os.environ.get("HEADLESS", "true").lower() != "false"


def cookies():
    c = []
    if SESSIONID_FILE.exists():
        sid = SESSIONID_FILE.read_text(encoding="utf-8").strip()
        if sid:
            c.append({"name": "sessionid", "value": sid, "domain": ".tiktok.com", "path": "/"})
    return c


async def main():
    out, seen = [], set()
    async with async_playwright() as p:
        b = await launch_browser(p, HEADLESS)
        ctx = await b.new_context(viewport={"width": 1400, "height": 900})
        await ctx.add_init_script("Object.defineProperty(navigator,'webdriver',{get:()=>undefined})")
        ck = cookies()
        if ck:
            await ctx.add_cookies(ck)
        page = await ctx.new_page()

        async def on_resp(r):
            if "/api/comment/list/" not in r.url:
                return
            try:
                d = await r.json()
            except Exception:
                return
            for c in d.get("comments") or []:
                cid = c.get("cid")
                if cid in seen:
                    continue
                seen.add(cid)
                u = c.get("user") or {}
                urls = (u.get("avatar_thumb") or {}).get("url_list") or []
                out.append({
                    "author": u.get("unique_id") or "",
                    "nickname": u.get("nickname") or "",
                    "avatar": urls[0] if urls else "",
                    "text": c.get("text") or "",
                    "likes": c.get("digg_count") or 0,
                })

        page.on("response", on_resp)
        try:
            await page.goto(URL, wait_until="domcontentloaded")
            await asyncio.sleep(1.5)
            # Comments only load once the comment panel is opened.
            try:
                await page.click("[data-e2e=comment-icon]", timeout=6000)
            except Exception:
                pass
            # First click loads ~20 comments; only scroll if we still need more.
            for _ in range(4):
                if len(out) >= TARGET:
                    break
                await page.mouse.wheel(0, 1600)
                await asyncio.sleep(0.8)
        finally:
            await b.close()

    print(json.dumps(out[:TARGET]))


if __name__ == "__main__":
    asyncio.run(main())
