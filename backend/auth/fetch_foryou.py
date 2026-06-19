"""
Reads your personalized For-You feed using a session cookie you provide.

We don't automate the login (TikTok blocks automated QR sign-in) and we don't
sign anything ourselves. You log in normally in your own Chrome, give us the
`sessionid` cookie, and we load tiktok.com/foryou with it — TikTok's own web app
makes its signed `recommend/item_list` requests, and we harvest the video list.

Provide the cookie either way:
  - env:  TIKTOK_SESSIONID=<value>           (just the one value; easiest)
  - file: backend/auth/cookies.txt           (Netscape format from a cookie-export extension)

Without a cookie it still returns an anonymous For-You feed (not personalized).

Prints JSON: [{"id":"123","url":"https://www.tiktok.com/@user/video/123"}, ...]

Usage:  python fetch_foryou.py [count]
Env:    HEADLESS=false  -> watch it in a visible window
"""
import asyncio
import json
import os
import sys
from pathlib import Path

from playwright.async_api import async_playwright

sys.path.insert(0, str(Path(__file__).parent))
from browser import launch_browser

COOKIE_FILE = Path(__file__).parent / "cookies.txt"
SESSIONID_FILE = Path(__file__).parent / "sessionid.txt"
TARGET = int(sys.argv[1]) if len(sys.argv) > 1 else 30
HEADLESS = os.environ.get("HEADLESS", "true").lower() != "false"


def load_cookies():
    """Collect cookies from (in priority order):
       1. auth/sessionid.txt  — just the raw sessionid value (easiest)
       2. TIKTOK_SESSIONID    — env var
       3. auth/cookies.txt    — full Netscape export
    """
    cookies = []
    if COOKIE_FILE.exists():
        for line in COOKIE_FILE.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) >= 7:
                domain, _flag, path, _secure, _exp, name, value = parts[:7]
                cookies.append({"name": name, "value": value,
                                "domain": domain, "path": path or "/"})

    sid = None
    if SESSIONID_FILE.exists():
        sid = SESSIONID_FILE.read_text(encoding="utf-8").strip()
    sid = sid or os.environ.get("TIKTOK_SESSIONID")
    if sid and not any(c["name"] == "sessionid" for c in cookies):
        cookies.append({"name": "sessionid", "value": sid,
                        "domain": ".tiktok.com", "path": "/"})
    return cookies


async def main():
    items = {}  # id -> url (preserves order, dedups)

    async with async_playwright() as p:
        browser = await launch_browser(p, HEADLESS)
        ctx = await browser.new_context()
        await ctx.add_init_script(
            "Object.defineProperty(navigator, 'webdriver', {get: () => undefined})"
        )
        cookies = load_cookies()
        if cookies:
            await ctx.add_cookies(cookies)
        else:
            print("[warn] no sessionid/cookies — returning anonymous feed", file=sys.stderr)

        page = await ctx.new_page()

        async def on_response(resp):
            if "/api/recommend/item_list/" not in resp.url:
                return
            try:
                data = await resp.json()
            except Exception:
                return
            for it in data.get("itemList", []):
                vid = it.get("id")
                a = it.get("author") or {}
                author = a.get("uniqueId")
                has_video = bool((it.get("video") or {}).get("playAddr"))
                if vid and author and has_video and vid not in items:
                    s = it.get("stats") or {}
                    mu = it.get("music") or {}
                    sound = (mu.get("title") or "").strip()
                    if mu.get("authorName"):
                        sound = f"{sound} - {mu['authorName']}".strip(" -")
                    items[vid] = {
                        "id": vid,
                        "url": f"https://www.tiktok.com/@{author}/video/{vid}",
                        "author": author,
                        "nickname": a.get("nickname") or author,
                        "avatar": a.get("avatarMedium") or a.get("avatarThumb") or "",
                        "verified": bool(a.get("verified")),
                        "caption": it.get("desc") or "",
                        "cover": (it.get("video") or {}).get("cover")
                                 or (it.get("video") or {}).get("originCover") or "",
                        "likes": s.get("diggCount") or 0,
                        "comments": s.get("commentCount") or 0,
                        "shares": s.get("shareCount") or 0,
                        "saves": s.get("collectCount") or 0,
                        "sound": sound,
                        "soundCover": mu.get("coverThumb") or "",
                    }

        page.on("response", on_response)

        try:
            await page.goto("https://www.tiktok.com/foryou", wait_until="domcontentloaded")
            await asyncio.sleep(2)  # the first item_list batch usually arrives here
            for _ in range(TARGET * 2):
                if len(items) >= TARGET:
                    break
                await page.keyboard.press("ArrowDown")
                await asyncio.sleep(1.0)
        finally:
            await browser.close()

    print(json.dumps(list(items.values())[:TARGET]))


if __name__ == "__main__":
    asyncio.run(main())
