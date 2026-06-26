// Seed sources for the "discovery" feed.
//
// TikTok's real For-You algorithm is unreachable without an authenticated,
// signed session, so we approximate a discovery feed by pulling recent videos
// from a curated set of popular accounts / hashtags and interleaving them.
//
// Edit this list freely. Each entry is any URL yt-dlp can list as a playlist:
//   - a user:    https://www.tiktok.com/@username
//   - a hashtag: https://www.tiktok.com/tag/funny
export const SOURCES = [
  'https://www.tiktok.com/@tiktok',
  'https://www.tiktok.com/@khaby.lame',
  'https://www.tiktok.com/@nba',
  'https://www.tiktok.com/@espn',
  'https://www.tiktok.com/@natgeo',
];

// How many videos to pull from each source when building the feed.
export const PER_SOURCE = 6;

// How long (ms) to cache a built feed / resolved video before refetching.
export const FEED_TTL_MS = 5 * 60 * 1000;      // 5 min
export const VIDEO_TTL_MS = 30 * 60 * 1000;    // 30 min (signed URLs expire)

// Max concurrent yt-dlp resolves (keep modest to avoid rate-limiting).
export const RESOLVE_CONCURRENCY = 4;

export const PORT = process.env.PORT || 8787;

// Feed source:
//   'sources' = anonymous curated feed from SOURCES above (no login)
//   'foryou'  = your personalized For-You feed (requires `python auth/login.py` first)
export const FEED_MODE = process.env.FEED_MODE || 'sources';
export const FORYOU_COUNT = Number(process.env.FORYOU_COUNT || 15);

// python3 on Linux/Pi/macOS, python on Windows (override with the PYTHON env var)
const DEFAULT_PYTHON = process.platform === 'win32' ? 'python' : 'python3';
export const PYTHON = process.env.PYTHON || DEFAULT_PYTHON;

// Max video width to download. TikTok is vertical, so widths are:
//   576 = 540p (smallest/fastest)   720 = 720p (balanced)   1080 = 1080p (sharpest)
// Higher = sharper but bigger/slower to buffer.
// Default 576 (540p): clips download/transcode ~2x faster than 720p and look
// identical inside the small phone-frame on screen. Set MAX_VIDEO_WIDTH=720/1080
// to trade speed for sharpness.
export const MAX_VIDEO_WIDTH = Number(process.env.MAX_VIDEO_WIDTH || 576);

// How to invoke yt-dlp. We use the pip module form so no separate binary needed.
export const YTDLP_CMD = process.env.YTDLP_CMD || DEFAULT_PYTHON;
export const YTDLP_ARGS_PREFIX = process.env.YTDLP_CMD ? [] : ['-m', 'yt_dlp'];

// Spoofs Chrome's TLS/HTTP2 fingerprint (via yt-dlp's curl_cffi backend) so
// TikTok's signature-based anti-bot checks see what looks like a real
// browser connection instead of a bare Python HTTP client — this is the
// difference between a clean response and the "status code 10240" /
// "Your IP address is blocked" failures we hit during testing. Requires
// curl_cffi (`pip install curl_cffi`), already a yt-dlp dependency here.
export const YTDLP_IMPERSONATE = ['--impersonate', 'chrome'];

// TikTok enforces a per-IP rate limit far below what running active playback
// + background prefetch + feed-resolve + audio-gain-analysis concurrently
// produces. Each of those already caps its OWN concurrency independently,
// but nothing previously capped the COMBINED total across all of them —
// confirmed by an actual IP block during testing, where the real cause
// wasn't any single subsystem but the sum of all of them hitting TikTok at
// once. MIN_YTDLP_INTERVAL_MS below paces every yt-dlp launch app-wide
// through one shared queue (see rateLimit.js) regardless of which subsystem
// triggered it.
export const MIN_YTDLP_INTERVAL_MS = Number(process.env.MIN_YTDLP_INTERVAL_MS || 1500);
