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

# Patches the handful of properties/behaviors sites check to fingerprint an
# automated/CDP-controlled browser — beyond just `navigator.webdriver`, which
# `--disable-blink-features=AutomationControlled` already hides. None of this
# can hide the DevTools Protocol connection itself (that's a deeper-level
# signal only a patched Chromium build, e.g. the `patchright` project, can
# mask) — but it removes the cheap, easy JS-visible tells that TikTok's
# anti-bot is most likely actually keying off, which is the gap between
# "real Chrome, manually driven" and "real Chrome, Playwright-attached".
STEALTH_JS = """
Object.defineProperty(navigator, 'webdriver', { get: () => undefined });

// A headless/automated Chrome reports 0 plugins/mimeTypes; a normal install
// always has the built-in PDF viewer entries.
Object.defineProperty(navigator, 'plugins', {
  get: () => [1, 2, 3, 4, 5].map(() => ({ name: 'Chrome PDF Plugin' })),
});
Object.defineProperty(navigator, 'languages', { get: () => ['en-US', 'en'] });

// window.chrome.runtime only exists on extension pages in a real browser —
// CDP-launched contexts often omit the whole `chrome` object, which itself
// is a tell. Stub the shape without granting it any real capability.
window.chrome = window.chrome || { runtime: {} };

// Headless/automated contexts report notification permission as "denied" by
// default in a way that differs from a real first-run profile.
const originalQuery = window.navigator.permissions.query;
window.navigator.permissions.query = (parameters) =>
  parameters.name === 'notifications'
    ? Promise.resolve({ state: Notification.permission })
    : originalQuery(parameters);

// outerWidth/outerHeight === innerWidth/innerHeight (no chrome around the
// viewport) is a classic headless tell — give it a normal window frame.
Object.defineProperty(window, 'outerWidth', { get: () => window.innerWidth });
Object.defineProperty(window, 'outerHeight', { get: () => window.innerHeight + 85 });
"""


def has_session(cookies):
    return any(c["name"] == "sessionid" and c.get("value") for c in cookies)


async def main():
    PROFILE_DIR.mkdir(exist_ok=True)
    async with async_playwright() as p:
        ctx = await p.chromium.launch_persistent_context(
            user_data_dir=str(PROFILE_DIR),
            headless=False,
            channel="chrome",  # use real Google Chrome — avoids bot detection
            viewport={"width": 1280, "height": 850},
            locale="en-US",
            timezone_id="Europe/Amsterdam",
            args=[
                "--disable-blink-features=AutomationControlled",
                "--no-first-run",
                "--no-default-browser-check",
                "--disable-infobars",
            ],
            # Removes the "Chrome is being controlled by automated test
            # software" infobar AND the automation indicators it implies —
            # Playwright adds --enable-automation by default.
            ignore_default_args=["--enable-automation"],
        )
        await ctx.add_init_script(STEALTH_JS)
        page = ctx.pages[0] if ctx.pages else await ctx.new_page()

        try:
            await page.goto("https://www.tiktok.com/login")
        except Exception as e:
            print(f"\n[!!] Couldn't load the login page: {e}")
            await ctx.close()
            return

        print("\n>>> Real Chrome opened. Log in (QR code / Google / email).")
        print(">>> It saves automatically once you're in.")
        print(">>> If it seems stuck but the browser shows your feed/avatar,")
        print("    press Enter here to force-save.\n")

        loop = asyncio.get_event_loop()
        enter = loop.run_in_executor(None, sys.stdin.readline)
        ticks = 0

        try:
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
        except Exception:
            print("\n[!!] The browser window was closed before login completed (by you, or by")
            print("     TikTok's anti-bot check). No session was saved — nothing to clean up,")
            print("     just run `python login.py` again.")
            return

        await ctx.close()


if __name__ == "__main__":
    asyncio.run(main())
