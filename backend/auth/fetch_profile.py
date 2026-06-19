"""
Fetch a channel's profile + video grid.

Grid videos come from yt-dlp (reliable, includes thumbnails + stats).
Header info (name, avatar, bio, follower/like counts, verified) comes from the
profile page's server-rendered userInfo via Playwright.

Usage:  python fetch_profile.py <username> [count]
Prints: {"user": {...}, "videos": [ {id, author, cover, caption, likes, ...} ]}
"""
import asyncio
import json
import os
import subprocess
import sys
from pathlib import Path

from playwright.async_api import async_playwright

sys.path.insert(0, str(Path(__file__).parent))
from browser import launch_browser

SESSIONID_FILE = Path(__file__).parent / "sessionid.txt"
USERNAME = sys.argv[1].lstrip("@")
TARGET = int(sys.argv[2]) if len(sys.argv) > 2 else 30
HEADLESS = os.environ.get("HEADLESS", "true").lower() != "false"

USERINFO_JS = """() => {
  try {
    const d = JSON.parse(document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__').textContent);
    const u = d['__DEFAULT_SCOPE__']['webapp.user-detail']['userInfo'];
    return { nickname: u.user.nickname, username: u.user.uniqueId, avatar: u.user.avatarLarger,
             signature: u.user.signature, verified: !!u.user.verified,
             followers: u.stats.followerCount, following: u.stats.followingCount,
             likes: u.stats.heartCount, videoCount: u.stats.videoCount };
  } catch (e) { return {}; }
}"""


def get_videos():
    url = f"https://www.tiktok.com/@{USERNAME}"
    r = subprocess.run(
        [sys.executable, "-m", "yt_dlp", "--flat-playlist", "--playlist-end",
         str(TARGET), "-J", "--no-warnings", url],
        capture_output=True, text=True,
    )
    try:
        d = json.loads(r.stdout)
    except Exception:
        return []
    out = []
    for e in d.get("entries", []):
        if not e.get("id"):
            continue
        thumbs = e.get("thumbnails") or []
        artists = e.get("artists") or []
        sound = ""
        if e.get("track"):
            sound = e["track"] + (" - " + artists[0] if artists else "")
        out.append({
            "id": e["id"],
            "author": e.get("uploader_id") or e.get("uploader") or USERNAME,
            "nickname": e.get("uploader") or e.get("channel") or "",
            "avatar": "",
            "verified": False,
            "caption": e.get("title") or e.get("description") or "",
            "cover": thumbs[-1]["url"] if thumbs else "",
            "likes": e.get("like_count") or 0,
            "comments": e.get("comment_count") or 0,
            "shares": e.get("repost_count") or 0,
            "saves": e.get("save_count") or 0,
            "plays": e.get("view_count") or 0,
            "sound": sound,
            "soundCover": "",
        })
    return out


async def get_header():
    user = {}
    async with async_playwright() as p:
        b = await launch_browser(p, HEADLESS)
        ctx = await b.new_context(viewport={"width": 1280, "height": 800})
        await ctx.add_init_script("Object.defineProperty(navigator,'webdriver',{get:()=>undefined})")
        if SESSIONID_FILE.exists():
            sid = SESSIONID_FILE.read_text(encoding="utf-8").strip()
            if sid:
                await ctx.add_cookies([{"name": "sessionid", "value": sid, "domain": ".tiktok.com", "path": "/"}])
        page = await ctx.new_page()
        try:
            try:
                await page.goto(f"https://www.tiktok.com/@{USERNAME}",
                                wait_until="domcontentloaded", timeout=30000)
            except Exception:
                pass
            await asyncio.sleep(1.5)
            try:
                user = await page.evaluate(USERINFO_JS)
            except Exception:
                user = {}
        finally:
            await b.close()
    return user or {}


async def main():
    videos = get_videos()
    user = await get_header()
    av, ver = user.get("avatar"), user.get("verified")
    for v in videos:
        if av and not v["avatar"]:
            v["avatar"] = av
        if ver:
            v["verified"] = True
    print(json.dumps({"user": user, "videos": videos}))


if __name__ == "__main__":
    asyncio.run(main())
