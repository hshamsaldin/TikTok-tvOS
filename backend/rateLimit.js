import { MIN_YTDLP_INTERVAL_MS } from './config.js';

// Serializes the START of every yt-dlp invocation app-wide with a minimum
// gap between launches. listSource/resolveVideo/ensureHls/analyzeGain each
// already cap their own concurrency, but those caps are independent of each
// other — nothing previously stopped them from all launching processes at
// the same moment. Awaiting this immediately before every yt-dlp spawn()
// call gives TikTok one paced stream of requests instead of several
// independently-bursty ones.
let lastCall = 0;
let chain = Promise.resolve();

export function throttleYtdlp() {
  const turn = chain.then(async () => {
    const wait = Math.max(0, lastCall + MIN_YTDLP_INTERVAL_MS - Date.now());
    if (wait > 0) await new Promise((r) => setTimeout(r, wait));
    lastCall = Date.now();
  });
  chain = turn.catch(() => {});
  return turn;
}
