"""Shared Playwright browser launcher that works on Windows and Linux/Pi.

- Windows: drives real Google Chrome (channel="chrome") to avoid bot detection.
- Linux/Pi/macOS: uses Playwright's bundled Chromium with --no-sandbox.
"""
import sys


async def launch_browser(p, headless=True):
    args = ["--disable-blink-features=AutomationControlled"]
    kwargs = {
        "headless": headless,
        "args": args,
        "ignore_default_args": ["--enable-automation"],
    }
    if sys.platform == "win32":
        kwargs["channel"] = "chrome"
    else:
        args.append("--no-sandbox")  # required for Chromium on most Linux/Pi setups
    return await p.chromium.launch(**kwargs)
