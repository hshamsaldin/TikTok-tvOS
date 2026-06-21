import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { PYTHON as PY } from './config.js';

const here = path.dirname(fileURLToPath(import.meta.url));

// Locate the bundled ffmpeg so yt-dlp can merge separate video+audio streams
// (without it, some clips download video-only = no sound).
let FFMPEG = '';
try {
  FFMPEG = execFileSync(PY, ['-c', 'import imageio_ffmpeg;print(imageio_ffmpeg.get_ffmpeg_exe())'])
    .toString().trim();
} catch {
  console.warn('ffmpeg not found — some clips may lack audio. `pip install imageio-ffmpeg`');
}
import { listSource, resolveVideo, listUserGrid } from './ytdlp.js';
import { fetchForYou } from './foryou.js';
import { fetchProfile } from './profile.js';
import {
  SOURCES, PER_SOURCE, FEED_TTL_MS, VIDEO_TTL_MS,
  RESOLVE_CONCURRENCY, PORT, FEED_MODE, FORYOU_COUNT,
  YTDLP_CMD, YTDLP_ARGS_PREFIX, MAX_VIDEO_WIDTH,
} from './config.js';

// Get a resolved video by id, using cache or a fresh yt-dlp resolve.
async function getResolved(id) {
  const cached = videoCache.get(id);
  if (cached && Date.now() - cached.ts < VIDEO_TTL_MS) return cached.item;
  const item = await resolveVideo(`https://www.tiktok.com/@_/video/${id}`);
  if (item.playUrl) videoCache.set(id, { ts: Date.now(), item });
  return item;
}

// ===== HLS streaming =====
// Pipe yt-dlp's download straight into ffmpeg, which segments it into an HLS
// playlist on the fly. AVPlayer plays the first segment within ~2s while the
// rest is still being produced — no waiting for a full download. Both video and
// audio are copied untouched (no re-encode, so this stays fast/low-CPU); per-clip
// loudness leveling happens separately, on-device, via AVAudioMix (see
// analyzeGain below) rather than a server-side transcode.
const hlsDir = (id) => path.join(os.tmpdir(), `tt-hls-${id}`);
const hlsJobs = new Map();
function hlsReady(id) {
  const d = hlsDir(id);
  return fs.existsSync(path.join(d, 'index.m3u8')) && fs.existsSync(path.join(d, 's0.ts'));
}

function ensureHls(id) {
  if (hlsReady(id)) return Promise.resolve(hlsDir(id));
  if (hlsJobs.has(id)) return hlsJobs.get(id);
  const dir = hlsDir(id);
  fs.mkdirSync(dir, { recursive: true });
  const playlist = path.join(dir, 'index.m3u8');

  const p = new Promise((resolve, reject) => {
    if (!FFMPEG) return reject(new Error('ffmpeg required for HLS'));
    const yt = spawn(YTDLP_CMD, [
      ...YTDLP_ARGS_PREFIX, '-o', '-', '--no-part', '--no-warnings', '--quiet',
      '-f', `b[vcodec^=h264][width<=${MAX_VIDEO_WIDTH}]/b[vcodec^=h264]/b`,
      `https://www.tiktok.com/@_/video/${id}`,
    ], { windowsHide: true });
    const ff = spawn(FFMPEG, [
      '-y', '-i', 'pipe:0', '-c', 'copy',
      '-f', 'hls', '-hls_time', '3', '-hls_list_size', '0',
      '-hls_flags', 'independent_segments+temp_file',
      '-hls_segment_filename', path.join(dir, 's%d.ts'), playlist,
    ], { windowsHide: true });

    yt.stdout.pipe(ff.stdin);
    yt.stderr.resume();
    let ferr = '';
    ff.stderr.on('data', (d) => { ferr += d; });
    yt.on('error', () => {});
    ff.on('error', reject);
    yt.on('close', () => { try { ff.stdin.end(); } catch {} });
    ff.on('close', () => { hlsJobs.delete(id); });

    const t0 = Date.now();
    const iv = setInterval(() => {
      if (hlsReady(id)) { clearInterval(iv); resolve(dir); }
      else if (Date.now() - t0 > 30000) {
        clearInterval(iv);
        try { yt.kill(); ff.kill(); } catch {}
        reject(new Error('hls timeout: ' + ferr.slice(-160)));
      }
    }, 150);
  });
  hlsJobs.set(id, p);
  p.catch(() => { hlsJobs.delete(id); });
  return p;
}

// ===== Audio loudness gain (native-side normalization) =====
// TikTok clips vary wildly in loudness. Re-encoding every clip's audio to a fixed
// level server-side (loudnorm) would mean decode+encode on every clip — real CPU
// cost on a path we want copy-only and fast. Instead: measure each clip's loudness
// ONCE with a cheap decode-only analysis pass (no re-encode), cache a single gain
// number, and let AVFoundation apply it on-device via AVAudioMix — the native
// AVFoundation mechanism for per-asset volume correction, with zero server re-encode.
// AVMutableAudioMixInputParameters.setVolume(_:at:) is documented to accept ONLY
// 0.0-1.0 — there is no API to boost a track above its native level this way.
// So TARGET_DBFS must sit near the LOUD end: quiet clips get little/no change
// (multiplier near 1, which is fine), loud outliers get pulled down to match.
// Picking -20 (the old value) meant most clips needed a >1.0 "boost" multiplier,
// which the API silently ignores — exactly why leveling wasn't working.
const TARGET_DBFS = -14;

// Persisted to disk: this was an in-memory-only Map, wiped on every backend
// restart. Since restarts happen often during normal use/testing, every video
// then needed its loudness re-measured from scratch — which means re-
// downloading the ENTIRE clip a second time (separate from the HLS pipeline's
// own download) just for analysis, for every single video, competing with the
// download that's actually trying to get the next video ready. Persisting
// across restarts removes that repeated cost entirely after the first measure.
const GAIN_CACHE_FILE = path.join(here, '.audio-gain-cache.json');
const audioGainCache = new Map(
  (() => {
    try { return Object.entries(JSON.parse(fs.readFileSync(GAIN_CACHE_FILE, 'utf8'))); }
    catch { return []; }
  })()
);
let gainSaveTimer = null;
function scheduleGainSave() {
  if (gainSaveTimer) return;
  gainSaveTimer = setTimeout(() => {
    gainSaveTimer = null;
    try { fs.writeFileSync(GAIN_CACHE_FILE, JSON.stringify(Object.fromEntries(audioGainCache))); } catch {}
  }, 2000).unref();
}

const audioGainJobs = new Map();

// Gain analysis spawns its OWN yt-dlp+ffmpeg pass, fully independent of the HLS
// pipeline — it must never compete with the video the user is about to watch.
// Capped at 1 concurrent job and only ever triggered lazily by an actual play
// (VideoCell.applyAudioGain), never eagerly during prefetch.
const GAIN_CONCURRENCY = 1;
let gainActive = 0;
const gainQueue = [];

function analyzeGain(id) {
  if (audioGainCache.has(id)) return Promise.resolve(audioGainCache.get(id));
  if (audioGainJobs.has(id)) return audioGainJobs.get(id);

  const p = new Promise((resolve) => {
    gainQueue.push({ id, resolve });
    drainGainQueue();
  });
  audioGainJobs.set(id, p);
  p.finally(() => audioGainJobs.delete(id));
  return p;
}

function drainGainQueue() {
  while (gainActive < GAIN_CONCURRENCY && gainQueue.length) {
    const { id, resolve } = gainQueue.shift();
    gainActive++;
    runGainAnalysis(id)
      .then(resolve)
      .finally(() => { gainActive--; drainGainQueue(); });
  }
}

function runGainAnalysis(id) {
  return new Promise((resolve) => {
    if (!FFMPEG) return resolve(0);
    const yt = spawn(YTDLP_CMD, [
      ...YTDLP_ARGS_PREFIX, '-o', '-', '--no-part', '--no-warnings', '--quiet',
      '-f', `b[vcodec^=h264][width<=${MAX_VIDEO_WIDTH}]/b[vcodec^=h264]/b`,
      `https://www.tiktok.com/@_/video/${id}`,
    ], { windowsHide: true });
    // -vn drops video entirely so this pass is audio-decode-only — cheap.
    const ff = spawn(FFMPEG, ['-i', 'pipe:0', '-vn', '-af', 'volumedetect', '-f', 'null', '-'],
      { windowsHide: true });
    let out = '';
    ff.stderr.on('data', (d) => { out += d; });
    yt.stdout.pipe(ff.stdin);
    yt.on('error', () => {});
    yt.stderr.resume();
    yt.on('close', () => { try { ff.stdin.end(); } catch {} });
    ff.on('error', () => resolve(0));
    ff.on('close', () => {
      const m = out.match(/mean_volume:\s*(-?\d+(\.\d+)?)\s*dB/);
      const mean = m ? parseFloat(m[1]) : null;
      // Clamp to <= 0: NEVER request a boost (10^(+dB/20) > 1.0, outside the
      // documented 0.0-1.0 range and silently ignored) — only ever attenuate.
      const gain = mean === null ? 0 : Math.max(-12, Math.min(0, TARGET_DBFS - mean));
      audioGainCache.set(id, gain);
      scheduleGainSave();
      resolve(gain);
    });
  });
}

// Background prefetch with limited concurrency: warm upcoming clips ahead of time
// WITHOUT starving the clip being watched (that one is fetched on-demand, ungated).
const PREFETCH_CONCURRENCY = 2;
let prefetchActive = 0;
const prefetchQueue = [];

function queuePrefetch(id) {
  // Gain analysis is intentionally NOT triggered here — it ran an unthrottled,
  // fully independent yt-dlp+ffmpeg pass for every prefetched clip, competing
  // with the HLS pipeline for the video the user is about to actually watch.
  // The client already requests /api/audiogain lazily when a clip starts
  // playing and tolerates it resolving late, so eager analysis here was pure
  // redundant load with no benefit — removing it frees real capacity for HLS.
  if (hlsReady(id) || hlsJobs.has(id) || prefetchQueue.includes(id)) return;
  prefetchQueue.push(id);
  drainPrefetch();
}

function drainPrefetch() {
  while (prefetchActive < PREFETCH_CONCURRENCY && prefetchQueue.length) {
    const id = prefetchQueue.shift();
    prefetchActive++;
    ensureHls(id)
      .catch(() => {})
      .finally(() => { prefetchActive--; drainPrefetch(); });
  }
}

// Warm the next few clips ahead of the one being watched so scrolling stays smooth.
function prefetchAround(id) {
  const data = feedCache.data || [];
  const i = data.findIndex((it) => it.id === id);
  if (i < 0) return;
  const upcoming = data.slice(i + 1, i + 5);
  upcoming.forEach((it) => queuePrefetch(it.id));   // warm next 4 clips
  // Also warm the CURRENT item's channel profile — if the user opens this
  // creator's channel (the most likely one to tap, since it's playing right
  // now), the page should already be loaded by the time they press right.
  queuePrefetchProfile(data[i]?.author);
}

// ---- tiny in-memory caches ----
let feedCache = { ts: 0, data: null };
const videoCache = new Map(); // id -> { ts, item }
const userCache = new Map(); // username -> { ts, data }
const profileJobs = new Map(); // username -> in-flight Promise<data>, dedupes concurrent fetches

// Cached + deduped channel-profile fetch. Without the in-flight map, a proactive
// background prefetch (queuePrefetchProfile) racing the user's actual tap on the
// same channel would spawn TWO Python+Playwright processes for the same profile.
function getProfile(username) {
  const key = 'p:' + username;
  const cached = userCache.get(key);
  if (cached && Date.now() - cached.ts < FEED_TTL_MS) return Promise.resolve(cached.data);
  if (profileJobs.has(username)) return profileJobs.get(username);

  const p = fetchProfile(username, 30).then((data) => {
    userCache.set(key, { ts: Date.now(), data });
    return data;
  });
  profileJobs.set(username, p);
  p.finally(() => profileJobs.delete(username));
  return p;
}

// Proactively warm a channel's profile in the background (called when the app
// starts playing one of that channel's videos, since opening their channel is a
// likely next action) so it's already cached by the time someone actually taps
// it — the same pre-warming strategy that fixed the main feed's loading time.
function queuePrefetchProfile(username) {
  if (!username) return;
  getProfile(username).catch(() => {});
}

// Keep several batches of videos pre-scraped AND their first clips downloaded, so
// the Apple TV never waits at a batch boundary. A background filler keeps the queue
// topped up; /api/more just pops a ready batch.
const READY_BATCHES = 2;          // how many batches to keep prepared ahead
const readyBatches = [];          // [items[], items[], …] already scraped
let filling = false;

async function fillBatches() {
  if (filling) return;
  filling = true;
  try {
    while (readyBatches.length < READY_BATCHES) {
      const items = await getFeedItems().catch(() => null);
      if (!items || !items.length) break;
      readyBatches.push(items);
      items.slice(0, 4).forEach((it) => queuePrefetch(it.id));   // warm its first clips
    }
  } finally {
    filling = false;
  }
}

// Back-compat shim: older call sites call primeMore() — just keep the queue full.
function primeMore() { fillBatches(); }

// Continuously keep the queue topped up so there's always a batch ready to serve.
setInterval(fillBatches, 4000).unref();

// Overlay fields. Prefer the feed entry's values (For-You item_list has stats +
// avatar) over yt-dlp's, which lacks them.
const META_KEYS = ['author', 'nickname', 'avatar', 'verified', 'caption',
  'likes', 'comments', 'shares', 'saves', 'sound', 'soundCover'];
function mergeMeta(resolved, entry) {
  const item = { ...resolved };
  for (const k of META_KEYS) {
    const v = entry[k];
    if (v !== undefined && v !== null && v !== '') item[k] = v;
  }
  return item;
}

// Resolve an array of {url} with bounded concurrency.
async function resolveAll(entries) {
  const out = [];
  let i = 0;
  async function worker() {
    while (i < entries.length) {
      const idx = i++;
      const e = entries[idx];
      const cached = videoCache.get(e.id);
      if (cached && Date.now() - cached.ts < VIDEO_TTL_MS) {
        out[idx] = cached.item;
        continue;
      }
      try {
        const resolved = await resolveVideo(e.url);
        if (resolved.playUrl) {
          const item = mergeMeta(resolved, e);
          videoCache.set(e.id, { ts: Date.now(), item });
          out[idx] = item;
        }
      } catch (err) {
        console.warn('resolve failed', e.id, String(err).slice(0, 120));
      }
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(RESOLVE_CONCURRENCY, entries.length) }, worker)
  );
  return out.filter(Boolean);
}

// Interleave videos from each source so the feed feels mixed, not blocky.
function interleave(lists) {
  const result = [];
  const max = Math.max(0, ...lists.map((l) => l.length));
  for (let r = 0; r < max; r++)
    for (const l of lists) if (l[r]) result.push(l[r]);
  return result;
}

// Produce ready-to-display feed items.
//  - For-You: the scrape already returns full items (id, author, stats, cover,
//    sound, avatar). No per-video yt-dlp pass needed — bytes are fetched lazily
//    by /api/hls. This is the big speedup.
//  - Sources: listSource only gives ids, so we resolve metadata via yt-dlp.
async function getFeedItems() {
  if (FEED_MODE === 'foryou') {
    return fetchForYou(FORYOU_COUNT);
  }
  const lists = await Promise.all(
    SOURCES.map((s) =>
      listSource(s, PER_SOURCE).catch((e) => {
        console.warn('list failed', s, String(e).slice(0, 120));
        return [];
      })
    )
  );
  return resolveAll(interleave(lists));
}

async function buildFeed() {
  if (feedCache.data && Date.now() - feedCache.ts < FEED_TTL_MS)
    return feedCache.data;

  const items = await getFeedItems();
  feedCache = { ts: Date.now(), data: items };
  // Warm the first several clips so the opening videos play instantly (queued
  // at limited concurrency so they don't all fight for CPU/network at once).
  items.slice(0, 4).forEach((it) => queuePrefetch(it.id));
  primeMore(); // start fetching the next batch now, while the user watches this one
  return items;
}

function send(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  try {
    if (url.pathname === '/health') return send(res, 200, { ok: true });

    // Web preview of the TV experience (open in Chrome on Windows).
    if (url.pathname === '/' || url.pathname === '/preview') {
      const html = fs.readFileSync(path.join(here, 'public', 'preview.html'));
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      return res.end(html);
    }

    if (url.pathname === '/api/feed') {
      const items = await buildFeed();
      return send(res, 200, { count: items.length, items });
    }

    // Fresh batch for infinite scroll — pop a pre-scraped batch (no wait at the
    // boundary) and refill the queue in the background.
    if (url.pathname === '/api/more') {
      if (!readyBatches.length) await fillBatches();
      const items = readyBatches.shift() || [];
      fillBatches();
      items.slice(0, 3).forEach((it) => queuePrefetch(it.id));
      return send(res, 200, { items });
    }

    // On-demand fresh resolve (for when a cached playUrl has expired).
    if (url.pathname.startsWith('/api/resolve/')) {
      const id = url.pathname.split('/').pop();
      const item = await getResolved(id);
      if (!item.playUrl) return send(res, 404, { error: 'no playable url' });
      return send(res, 200, item);
    }

    // A channel's profile + video grid (tap an author/avatar).
    if (url.pathname.startsWith('/api/profile/')) {
      const username = decodeURIComponent(url.pathname.split('/').pop()).replace(/^@/, '');
      const data = await getProfile(username);
      return send(res, 200, data);
    }

    // A page of a channel's videos for the profile grid's "Load more".
    if (url.pathname.startsWith('/api/user-videos/')) {
      const username = decodeURIComponent(url.pathname.split('/').pop()).replace(/^@/, '');
      const start = Number(url.searchParams.get('start') || 0);
      const count = Number(url.searchParams.get('count') || 30);
      const videos = await listUserGrid(username, start, count);
      return send(res, 200, { videos });
    }

    // A channel's recent videos (tap an author/avatar to browse them).
    if (url.pathname.startsWith('/api/user/')) {
      const username = decodeURIComponent(url.pathname.split('/').pop()).replace(/^@/, '');
      const cached = userCache.get(username);
      if (cached && Date.now() - cached.ts < FEED_TTL_MS) {
        return send(res, 200, { items: cached.data });
      }
      const entries = await listSource(`https://www.tiktok.com/@${username}`, 12);
      const items = await resolveAll(entries);
      userCache.set(username, { ts: Date.now(), data: items });
      return send(res, 200, { items });
    }

    // Loudness gain for AVAudioMix (analysis-only, no re-encode — see analyzeGain).
    if (url.pathname.startsWith('/api/audiogain/')) {
      const id = url.pathname.split('/').pop().replace(/[^\w-]/g, '');
      const gain = await analyzeGain(id);
      return send(res, 200, { gain });
    }

    // HLS streaming: AVPlayer plays this. index.m3u8 starts (or reuses) the
    // pipe→ffmpeg→HLS job and serves the playlist; sN.ts serves each segment as
    // it's produced. First frame in ~2s — no full-download wait.
    if (url.pathname.startsWith('/api/hls/')) {
      const parts = url.pathname.slice('/api/hls/'.length).split('/');
      const id = (parts[0] || '').replace(/[^\w-]/g, '');
      const file = path.basename(parts[1] || 'index.m3u8');
      if (!id) return send(res, 404, { error: 'no id' });

      if (file === 'index.m3u8') {
        prefetchAround(id);                       // warm the next few in the background
        try { await ensureHls(id); } catch (e) { return send(res, 500, { error: String(e).slice(0, 160) }); }
        const data = fs.readFileSync(path.join(hlsDir(id), 'index.m3u8'));
        res.writeHead(200, { 'Content-Type': 'application/vnd.apple.mpegurl', 'Cache-Control': 'no-cache' });
        return res.end(data);
      }
      if (file.endsWith('.ts')) {
        const fp = path.join(hlsDir(id), file);
        for (let i = 0; i < 80 && !fs.existsSync(fp); i++) await new Promise((r) => setTimeout(r, 100));
        if (!fs.existsSync(fp)) return send(res, 404, { error: 'segment not ready' });
        const data = fs.readFileSync(fp);
        res.writeHead(200, { 'Content-Type': 'video/mp2t', 'Content-Length': data.length });
        return res.end(data);
      }
      return send(res, 404, { error: 'bad hls path' });
    }


    send(res, 404, { error: 'not found' });
  } catch (e) {
    send(res, 500, { error: String(e).slice(0, 200) });
  }
});

// Delete cached clips/HLS dirs older than an hour so the temp dir doesn't grow.
function cleanupTemp() {
  const dir = os.tmpdir();
  for (const f of fs.readdirSync(dir)) {
    if (!f.startsWith('tt-')) continue;
    const fp = path.join(dir, f);
    try {
      if (Date.now() - fs.statSync(fp).mtimeMs <= 60 * 60 * 1000) continue;
      fs.rmSync(fp, { recursive: true, force: true });   // file or tt-hls-* dir
    } catch {}
  }
}
cleanupTemp();
setInterval(cleanupTemp, 30 * 60 * 1000).unref();

// How many clips to fully download on startup before declaring "ready".
const PREWARM_COUNT = Number(process.env.PREWARM_COUNT || 6);

// Download a list of ids with limited concurrency, reporting progress.
async function prewarmClips(ids, concurrency, onProgress) {
  let next = 0, done = 0;
  async function worker() {
    while (next < ids.length) {
      const id = ids[next++];
      try { await ensureHls(id); } catch {}
      onProgress(++done, ids.length);
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, ids.length) }, worker));
}

// Pre-warm on startup: scrape the feed AND download the first clips NOW, so when
// the app opens everything is ready and the loading screen resolves instantly.
async function prewarmOnStartup() {
  const t0 = Date.now();
  console.log('\n⏳  Pre-warming — scraping For-You feed…');
  let items;
  try {
    items = await buildFeed();
  } catch (e) {
    console.warn('⚠️  feed scrape failed (will retry on first request):', String(e).slice(0, 120));
    return;
  }
  const n = Math.min(items.length, PREWARM_COUNT);
  console.log(`📋  Feed ready: ${items.length} videos. Preloading first ${n} clips…`);
  await prewarmClips(
    items.slice(0, n).map((x) => x.id),
    PREFETCH_CONCURRENCY,
    (d, total) => process.stdout.write(`\r    downloaded ${d}/${total} clips…   `)
  );
  const secs = ((Date.now() - t0) / 1000).toFixed(1);
  console.log(`\n✅  READY in ${secs}s — open the app now (${n} videos preloaded).\n`);
}

server.listen(PORT, () => {
  console.log(
    `tiktok-appletv backend on http://0.0.0.0:${PORT}  (/api/feed)  mode=${FEED_MODE}`
  );
  prewarmOnStartup();
});
