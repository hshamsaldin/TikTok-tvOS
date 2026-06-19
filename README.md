# TikTok for Apple TV (sideloaded)

A native tvOS app that plays a TikTok-style vertical video feed, with the feed
assembled by a small backend on your PC. Built specifically for a **no-Mac**
workflow: write code on Windows, build the IPA on a free cloud macOS runner,
sideload from Windows.

```
[ Apple TV ]  ──fetch JSON──►  [ backend on your PC ]  ──yt-dlp──►  TikTok
  native AVPlayer feed              /api/feed
```

## Why it's built this way

- TikTok has **no official Apple TV app** and tvOS has **no web view**, so a
  native AVPlayer client is the only route to a native feel.
- TikTok's real "For You" algorithm is unreachable (no API; requires signed,
  authenticated sessions). This approximates a discovery feed by interleaving
  recent videos from a curated list of accounts/hashtags — edit them in
  `backend/config.js`.

---

## 1. Backend (runs on your Windows PC)

Requires Python (for `yt-dlp`) and Node 18+.

```powershell
pip install -U yt-dlp curl_cffi      # curl_cffi enables impersonation -> fewer blocks
cd backend
node server.js                       # serves http://0.0.0.0:8787/api/feed
```

Test it: open <http://localhost:8787/api/feed>. Edit `config.js` `SOURCES` to
change what shows up in the feed.

Find your PC's LAN IP (`ipconfig` → IPv4 Address). The Apple TV must be on the
same Wi-Fi/LAN.

### Preview the experience on Windows (no Mac/Apple TV needed)

With the backend running, open **`http://localhost:8787/`** in Chrome for a
full-screen vertical web preview of the feed — same `/api/feed` + `/api/stream`
the TV app uses. Arrow keys / scroll to navigate, click to unmute. Good for
testing the feed + playback before sideloading.

### Personalized For-You feed (optional)

By default the feed is anonymous (`FEED_MODE=sources`). To get **your own
personalized For-You feed**, give the backend your `sessionid` cookie.

> We do NOT automate the login — TikTok blocks automated (QR) sign-in. Instead
> you log in normally in your own Chrome and hand over one cookie value.

**1. Set up Playwright (one-time):**
```powershell
cd backend
pip install -U playwright
python -m playwright install chromium
```

**2. Get your `sessionid`:** In your normal Chrome (logged into TikTok), open
`tiktok.com` → press **F12** → **Application** → **Cookies** →
`https://www.tiktok.com` → copy the **Value** of the `sessionid` row.

(Alternatively, export all tiktok.com cookies with a "Get cookies.txt" extension
and save them to `backend/auth/cookies.txt` — more complete and longer-lived.)

**3. Run in For-You mode:**
```powershell
$env:TIKTOK_SESSIONID = "<your sessionid value>"
$env:FEED_MODE = "foryou"
node server.js
```

How it works: a headless Chrome loads `tiktok.com/foryou` with your cookie and
lets **TikTok's own web app sign its requests** — we just harvest the video list
it loads, then resolve playable URLs with yt-dlp (same as the anonymous path). No
signature reverse-engineering.

> ⚠️ `sessionid` is full account access — treat it like a password and use a
> **throwaway account**. If the feed comes back empty, run with
> `$env:HEADLESS = "false"` to watch what TikTok shows the fetcher.

## 2. tvOS app

1. Edit `tvos/Sources/Config.swift` → set `backendBaseURL` to your PC's IP,
   e.g. `http://192.168.1.50:8787`.
2. Push this repo to **GitHub**. The workflow in `.github/workflows/build-tvos.yml`
   runs on a cloud macOS runner, builds an **unsigned** `.ipa`, and uploads it as
   a build artifact (Actions tab → latest run → Artifacts → `TikTokTV-unsigned-ipa`).
   - Free macOS minutes for **public** repos; private repos consume Actions minutes.
   - No Apple Developer account or signing certs needed at this stage.

> Building locally instead? On any Mac: `cd tvos && xcodegen generate && open TikTokTV.xcodeproj`.

## 3. Sideload to the Apple TV (from Windows)

1. Install [Sideloadly](https://sideloadly.io/) on Windows.
2. Put the Apple TV into pairing mode and pair it (Sideloadly / `atvloadly` docs).
3. Drag the downloaded `TikTokTV-unsigned.ipa` into Sideloadly, sign in with a
   free Apple ID → install.
   - Free Apple ID = app works **7 days**, then re-sign. Paid dev account = 1 year.

---

## Known risks / next steps

- **Video URL headers/expiry.** TikTok CDN URLs are signed and expire, and may
  require a browser-like `User-Agent` (the app already sends one). If clips fail
  to play (403), the fix is to add a **proxy endpoint** on the backend
  (`/api/stream/:id`) that fetches the video with the right headers/cookies and
  streams the bytes to the app. Hook the app's player to that instead of the raw
  CDN URL. The `/api/resolve/:id` endpoint already re-resolves a fresh URL.
- **Blurred pillarbox fill.** Vertical clips currently show black bars on the
  sides (`.resizeAspect`). A blurred, scaled copy of the video as the background
  is a nice follow-up.
- **Feed quality.** It's a curated-source approximation, not the FYP. Add more
  sources / hashtags in `config.js`, or wire up authenticated extraction later.
- **ToS.** Unofficial extraction violates TikTok's terms — fine for a personal
  sideloaded build, not for distribution.
