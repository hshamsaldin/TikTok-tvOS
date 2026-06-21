# Handover — TikTok for Apple TV

Status as of commit `d12d6da`. Repo: https://github.com/hshamsaldin/TikTok-tvOS (private).

This is a from-scratch native tvOS TikTok client (no official one exists) with a
small Node/Python backend that does the scraping/streaming work a tvOS app
can't do itself. The app is feature-complete and has been sideloaded and used
on a real Apple TV; this doc is for picking the project back up cleanly.

## 1. Architecture

```
[ Apple TV — native UIKit/AVPlayer ]  ──HTTP──►  [ backend on a PC/Pi ]  ──yt-dlp/Playwright──►  TikTok
        tvos/                                          backend/
```

- **tvOS app** (`tvos/Sources/`): Swift, UIKit (SwiftUI is just a thin
  `App`/`WindowGroup` wrapper around one `UIViewControllerRepresentable`).
  XcodeGen project (`tvos/project.yml`), built unsigned by CI, sideloaded with
  **atvloadly** (not Sideloadly — README is stale on this point).
- **Backend** (`backend/`): Node ESM `server.js` + Python helper scripts under
  `backend/auth/`. Does feed scraping, video resolution, and **on-the-fly HLS
  transcoding** (pipes `yt-dlp` straight into `ffmpeg`, `-c copy`, no
  re-encode) so the TV gets a playable stream in ~2s instead of waiting for a
  full download.
- No backend = no app. TikTok's CDN URLs are signed/session-bound, the
  personalized feed needs a real browser (Playwright) to let TikTok's own JS
  sign its requests, and tvOS can't run any of that itself. This was
  re-litigated once this session — the honest answer is still no.

## 2. Running it

```powershell
cd backend
node server.js
```
Wait for the `✅ READY in Xs` line (the backend pre-warms the feed + first
`PREWARM_COUNT` clips on startup so the app's first load is instant). Set
`tvos/Sources/Config.swift`'s `backendBaseURL` to the backend PC's LAN IP —
currently hardcoded to `http://192.168.0.100:8787`.

For the personalized For-You feed: `FEED_MODE=foryou` + a `sessionid` cookie in
`backend/auth/sessionid.txt` (gitignored, never commit it — use a throwaway
account, see README for how to obtain it).

**Build**: push to `main` → `.github/workflows/build-tvos.yml` (macos-15
runner, XcodeGen, unsigned IPA) → download the `TikTokTV-unsigned-ipa`
artifact → sideload with atvloadly. The CI helper pattern used all session:
push, then poll `https://api.github.com/repos/hshamsaldin/TikTok-tvOS/actions/runs`
with a stored git credential token (see any recent commit in `git log -p` for
the exact polling snippet).

## 3. Backend — key pieces (`backend/server.js`)

| Piece | What it does |
|---|---|
| `ensureHls(id)` | Pipes `yt-dlp -o -` → `ffmpeg -c copy -f hls`, serves the growing playlist at `/api/hls/:id/index.m3u8` + `/api/hls/:id/sN.ts`. **This is the only streaming path** — the old per-clip MP4 download/transcode pipeline (`ensureLocalFile`, `/api/stream/:id`) was fully removed this session as dead code. |
| `queuePrefetch`/`drainPrefetch` | Warms upcoming clips, `PREFETCH_CONCURRENCY = 2` (deliberately capped — more concurrency measurably slowed the clip actually being watched). |
| `fillBatches()` | Keeps `READY_BATCHES = 2` feed batches pre-scraped + their first clips warmed, refilled every 4s in the background — `/api/more` just pops a ready one, no cold-scrape wait at the batch boundary. |
| `prewarmOnStartup()` | Scrapes the feed and downloads the first `PREWARM_COUNT` (default 6) clips before printing `✅ READY`, so opening the app right after is instant. |
| `analyzeGain`/`runGainAnalysis` | Decode-only loudness measurement per clip (no re-encode), persisted to `backend/.audio-gain-cache.json` (gitignored) so it survives restarts. **As of this session, unused by the app** — superseded by the on-device real-time leveler (§5). Left in place as a fallback, not deleted. |
| `fetch_profile.py` | Channel page data. Runs the yt-dlp video listing and the Playwright header scrape **concurrently** (`asyncio.gather`), and waits for the actual hydration selector instead of a blind `sleep(1.5)` — this was a real, measured slowdown fix this session. |

Comments (`comments.js`, `fetch_comments.py`, `/api/comments`, `commentsCache`)
were removed entirely this session — confirmed dead after the app-side
comments feature was dropped.

## 4. tvOS app — key files (`tvos/Sources/`)

| File | Role |
|---|---|
| `TikTokTVApp.swift` | SwiftUI entry point. Sets `AVAudioSession` category (`.playback`/`.moviePlayback`) at launch; **activation** happens lazily on first play (see §6 — doing it at launch fails silently). |
| `FeedViewController.swift` | The vertical feed. `UICollectionView` + a 5-player preload pool (`poolMax = 5`, preloads index+1/+2/+3). Tracks `targetIndex` explicitly for paging instead of reading `contentOffset` (fixes double-press feeling unresponsive mid-scroll-animation). Pauses on `UIApplication.didEnterBackgroundNotification` (see §6). Right swipe/click → channel page. |
| `VideoCell.swift` | One video. `AVPlayerViewController` (chrome hidden, custom UI drawn over it). Dynamic aspect ratio via `updateStageAspect` (some creators post landscape, not just 9:16 — handled, not assumed). `stageShadow` elevation effect (separate non-clipping sibling view). `play()` always seeks to 0 first (fixes "previous video doesn't restart"/inaccurate progress bar). |
| `LiveAudioLeveler.swift` | **New, untested on device as of this handover.** Real-time peak limiter via `MTAudioProcessingTap` (confirmed tvOS 9.0+ against the live docs) — modifies PCM samples in place as they play, no backend measurement. See §5. |
| `ProfileViewController.swift` | Channel/profile page. Grid spacing is **Apple's exact documented four-column spec**, not approximated — see §7. |
| `NowPlayingCenter.swift` | User-modified — minimal `MPRemoteCommandCenter` setup, don't revert without asking. |
| `AppFont.swift` | Bundled Inter font (`tvos/Resources/Fonts/`, registered in `Info.plist` `UIAppFonts`). |

## 5. ⚠️ Needs device verification: the new audio leveler

The previous approach (backend measures loudness via `ffmpeg volumedetect`,
app applies a static dB gain via `AVAudioMix.setVolume`) **worked**, but the
user wanted true real-time Apple-native leveling with no pre-measurement.

`LiveAudioLeveler.swift` is a from-scratch `MTAudioProcessingTap`-based
limiter, built this session, with every callback signature verified
field-by-field against the live Apple docs (not memory) — see the commit
message on `d12d6da` for exactly what was checked. **It has not yet been
confirmed working on a real device.** If you're picking this up:

1. Ask the user: does audio still play (not silent, no crash), and do
   loud/quiet clips actually sound more even now?
2. If it's broken, the **old path still exists** — `API.audioGain` and the
   backend's `/api/audiogain` route were deliberately left in place, unused,
   as a fallback. Revert `VideoCell.applyAudioGain` to call `API.audioGain`
   again rather than re-deriving the tap approach from scratch.
3. One thing to watch for specifically: `MTAudioProcessingTapCallbacks` has a
   documented 64-bit alignment gotcha — Apple's own docs say to assign each
   callback field individually, not pack them into one struct literal. The
   current code does this correctly; don't "simplify" it back into one
   initializer call.

## 6. Hard-won lessons — read before re-debugging audio/focus issues

These cost real time this session. Don't re-discover them the hard way:

- **A dead HDMI port caused hours of false debugging.** If "no audio" comes
  back, check the *physical output* (try a different HDMI port, check if
  *other* apps have sound on the same output) **before** touching any code.
  Every prior "fix" attempt was chasing a real software issue that turned out
  not to be the actual cause of that particular silence.
- **AirPlay/Sonos audio routing** needs `AVAudioSession` category
  `.playback`/`.moviePlackback` with **policy `.longFormAudio`** (not
  `.longFormVideo` — that's iOS-only and won't compile on tvOS), plus
  `UIBackgroundModes: [audio]` in `Info.plist`.
- **Activate the audio session lazily**, on first `play()`, not in
  `App.init()` — doing it at launch fails silently on tvOS.
- **tvOS needs something focusable on screen at all times** for the Menu/Back
  button and remote presses to be delivered at all — see the
  `RemoteInputView`/`focusFallback` pattern in `FeedViewController` and
  `ProfileViewController`. A screen with zero focusable items (e.g. a
  collection view with 0 cells while loading) can silently break Back.
- **Reused `UICollectionViewCell`s don't reset custom visual state for free.**
  `prepareForReuse()` must explicitly reset anything set in `didUpdateFocus`
  (transform/shadow/border) or a custom shadow view's frame — this caused two
  separate "stale shadow on the wrong video" bugs this session (one in
  `GridCell`, one in `VideoCell`'s `stageShadow`).
- **`AVMutableAudioMixInputParameters.setVolume` only accepts 0.0–1.0** — there
  is no way to *boost* a track above its native level this way, only
  attenuate. A gain calculation that can produce >0dB will silently no-op.
- **Apple's tvOS Layout HIG gives exact pixel values**, not vibes — four-column
  grid: 410pt card width, 40pt horizontal/100pt vertical spacing, 80pt side /
  60pt top-bottom safe area, calibrated for a 1920×1080pt reference canvas
  (`80 + 410×4 + 40×3 + 80 = 1920` exactly). `ProfileViewController.swift` uses
  these literally. Don't re-approximate them if revisiting the grid.

## 7. How to read Apple's docs when they're JS-rendered

`developer.apple.com` (both the HIG and the API reference) is a JavaScript
single-page app — a plain fetch tool only ever gets the empty page shell, no
real text, on **every** URL there, not just some.

**The fix used all session**: a real headless-Chromium CLI tool called
`playwright-cli` is already installed on the user's machine
(`C:\Users\hussein\AppData\Roaming\npm\node_modules\@playwright\cli`). Pattern:

```powershell
playwright-cli goto "https://developer.apple.com/documentation/..."
playwright-cli eval "new Promise(r => setTimeout(() => r(document.body.innerText.slice(0, 4000)), 1500))"
```

The HIG pages' real content lives under `#app-main`; plain API reference
(DocC) pages don't have that element — just grab `document.body.innerText`
directly. If a URL 404s, use `playwright-cli goto "https://developer.apple.com/search/?q=..."`
and read the snapshot for the real link (the AI-answer panel is unreliable;
the actual search result links are in the page snapshot).

## 8. Explicitly out of scope (already decided with the user)

- **Top Shelf** (dynamic Home Screen content extension) — user said skip it.
  Static Top Shelf image assets already exist (`generate_icons.py`).
- **SharePlay, TV app integration, TV provider accounts** — don't apply to a
  personal project; covered in Apple's "Designing for tvOS" overview, decided
  not relevant.
- **Comments** — removed entirely, on purpose, both app and backend.
- **Eliminating the backend** — not feasible; re-asked and re-answered this
  session (§1).

## 9. Stale docs to be aware of

`README.md` predates most of this session's work — it still describes the
old `/api/stream` MP4 path, mentions Sideloadly instead of atvloadly, and
lists "blurred pillarbox fill" as a TODO that's long since shipped. Trust
this file and the code over the README until someone updates it.
