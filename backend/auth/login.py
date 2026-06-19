"""
One-time login helper.

Drives your REAL installed Google Chrome (not bundled Chromium) in a dedicated
profile, so TikTok doesn't flag it as automation and QR/Google login actually
completes. Log in however you like; the session persists in the profile folder
and the feed reuses it.

It auto-saves once it sees you're logged in. If auto-detect misses it, press
Enter in this terminal once the browser shows your TikTok feed/avatar.

    python login.py
"""
import asyncio
import sys
from pathlib import Path

from playwright.async_api import async_playwright

PROFILE_DIR = Path(__file__).parent / "chrome-profile"


def has_session(cookies):
    return any(c["name"] == "sessionid" and c.get("value") for c in cookies)


async def main():
    PROFILE_DIR.mkdir(exist_ok=True)
    async with async_playwright() as p:
        ctx = await p.chromium.launch_persistent_context(
            user_data_dir=str(PROFILE_DIR),
            headless=False,
            channel="chrome",  # use real Google Chrome — avoids bot detection
            args=["--disable-blink-features=AutomationControlled"],
        )
        await ctx.add_init_script(
            "Object.defineProperty(navigator, 'webdriver', {get: () => undefined})"
        )
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()
        await page.goto("https://www.tiktok.com/login")

        print("\n>>> Real Chrome opened. Log in (QR code / Google / email).")
        print(">>> It saves automatically once you're in.")
        print(">>> If it seems stuck but the browser shows your feed/avatar,")
        print("    press Enter here to force-save.\n")

        loop = asyncio.get_event_loop()
        enter = loop.run_in_executor(None, sys.stdin.readline)
        ticks = 0

        while True:
            cookies = await ctx.cookies()
            if has_session(cookies):
                print(f"\n[OK] Logged in. Session saved in {PROFILE_DIR}")
                print(">>> Close the browser. Start the feed with FEED_MODE=foryou.\n")
                break

            if enter.done():
                if has_session(await ctx.cookies()):
                    print(f"\n[OK] Session saved in {PROFILE_DIR}\n")
                    break
                print("[..] No session cookie yet — finish logging in, then press Enter.")
                enter = loop.run_in_executor(None, sys.stdin.readline)

            await asyncio.sleep(2)
            ticks += 1
            if ticks % 15 == 0:
                print("[..] still waiting — log in in the browser, then press Enter here.")

        await ctx.close()


if __name__ == "__main__":
    asyncio.run(main())
