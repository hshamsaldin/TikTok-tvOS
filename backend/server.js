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
import { fetchComments } from './comments.js';
import { fetchProfile } from './profile.js';
import {
  SOURCES, PER_SOURCE, FEED_TTL_MS, VIDEO_TTL_MS,
  RESOLVE_CONCURRENCY, PORT, FEED_MODE, FORYOU_COUNT,
  YTDLP_CMD, YTDLP_ARGS_PREFIX, MAX_VIDEO_WIDTH, SKIP_TRANSCODE,
} from './config.js';

// Get a resolved video by id, using cache or a fresh yt-dlp resolve.
async function getResolved(id) {
  const cached = videoCache.get(id);
  if (cached && Date.now() - cached.ts < VIDEO_TTL_MS) return cached.item;
  const item = await resolveVideo(`https://www.tiktok.com/@_/video/${id}`);
  if (item.playUrl) videoCache.set(id, { ts: Date.now(), item });
  return item;
}

// Direct CDN requests get 403 (the URL is bound to yt-dlp's exact session), so
// we let yt-dlp download the clip to a temp file, then serve that file with
// Range support. Cached on disk per id; concurrent requests share one download.
const downloads = new Map(); // id -> Promise<filePath>
// Final served file. The "-aac" suffix also invalidates any older cache that
// still has the silent HE-AACv2 track, so those get re-processed automatically.
const localFileFor = (id) =>
  path.join(os.tmpdir(), `tt-${id}-${SKIP_TRANSCODE ? 'raw' : 'aac'}.mp4`);

// ids whose on-disk file we've confirmed this run is NOT silent HE-AACv2, so we
// don't re-probe on every stream request (probing spawns ffmpeg = not free).
const verifiedAudio = new Set();

// Probe a file's audio codec via `ffmpeg -i` (stream info goes to stderr).
// Returns 'he' (HE-AAC/HE-AACv2 → silent on tvOS, must re-transcode), 'lc'
// (AAC-LC → good), 'none' (no audio track), or 'unknown' (couldn't probe, e.g.
// no ffmpeg). Only 'he' triggers a rebuild — the rest are served as-is.
function probeAudio(file) {
  return new Promise((resolve) => {
    if (!FFMPEG) return resolve('unknown');
    const ff = spawn(FFMPEG, ['-hide_banner', '-i', file], { windowsHide: true });
    let s = '';
    ff.stderr.on('data', (d) => (s += d));
    ff.on('error', () => resolve('unknown'));
    ff.on('close', () => {
      const m = s.match(/Audio:\s*([^\n,]+)/i);
      if (!m) return resolve('none');
      const desc = m[1].toLowerCase();
      if (desc.includes('he-aac')) return resolve('he');
      if (desc.includes('aac')) return resolve('lc');
      resolve('unknown');
    });
  });
}

function ensureLocalFile(id) {
  const out = localFileFor(id);
  if (downloads.has(id)) return downloads.get(id);
  if (fs.existsSync(out) && fs.statSync(out).size > 0) {
    if (SKIP_TRANSCODE || verifiedAudio.has(id)) return Promise.resolve(out);
    // Validate the cached file's audio ONCE per run: a file left by a previous
    // run that had no ffmpeg (or an older build) can be silent HE-AACv2. Only
    // those get deleted and rebuilt; good/unknown files are served immediately.
    const p = probeAudio(out).then((kind) => {
      if (kind !== 'he') { verifiedAudio.add(id); return out; }
      try { fs.unlinkSync(out); } catch {}   // drop the stale silent file
      downloads.delete(id);
      return ensureLocalFile(id);            // re-download + transcode
    });
    downloads.set(id, p);
    p.catch(() => {}).finally(() => { if (downloads.get(id) === p) downloads.delete(id); });
    return p;
  }

  const src = path.join(os.tmpdir(), `tt-${id}.src.mp4`);
  const ok = (f) => fs.existsSync(f) && fs.statSync(f).size > 0;

  const p = new Promise((resolve, reject) => {
    const args = [
      ...YTDLP_ARGS_PREFIX,
      '-o', src, '--no-part', '--no-warnings', '--quiet',
      // Prefer h264 (+aac) up to MAX_VIDEO_WIDTH (vertical, so filter by width).
      // Merge if that rendition is video-only; fall back to any h264, then anything.
      '-f', `b[vcodec^=h264][width<=${MAX_VIDEO_WIDTH}]/bv*[vcodec^=h264][width<=${MAX_VIDEO_WIDTH}]+ba/b[vcodec^=h264]/bv*[vcodec^=h264]+ba/bv*+ba/b`,
      '--merge-output-format', 'mp4',
      ...(FFMPEG ? ['--ffmpeg-location', FFMPEG] : []),
      `https://www.tiktok.com/@_/video/${id}`,
    ];
    const child = spawn(YTDLP_CMD, args, { windowsHide: true });
    let err = '';
    child.stderr.on('data', (d) => (err += d));
    child.on('error', reject);
    child.on('close', (code) => {
      if (!(code === 0 && ok(src))) {
        downloads.delete(id);
        reject(new Error(`download failed (${code}): ${err.slice(-200)}`));
        return;
      }
      // TikTok ships HE-AACv2 audio, which tvOS AVPlayer plays SILENTLY (the track
      // is present + "playing" but the hardware PS decoder outputs nothing). Remux
      // with the audio transcoded to plain AAC-LC (video copied, no quality loss),
      // which every Apple device plays reliably. +faststart for instant playback.
      if (!FFMPEG) {
        try { fs.renameSync(src, out); } catch {}
        downloads.delete(id);
        return ok(out) ? resolve(out) : reject(new Error('download produced empty file'));
      }
      // SKIP_TRANSCODE: remux only (keep TikTok's original audio) to test whether it
      // plays on tvOS. Otherwise transcode audio to AAC-LC (video copied either way).
      const ffArgs = SKIP_TRANSCODE
        ? ['-y', '-i', src, '-c', 'copy', '-movflags', '+faststart', out]
        : ['-y', '-i', src, '-c:v', 'copy', '-c:a', 'aac', '-profile:a', 'aac_low',
           '-ar', '44100', '-b:a', '128k', '-movflags', '+faststart', out];
      const ff = spawn(FFMPEG, ffArgs, { windowsHide: true });
      let ferr = '';
      ff.stderr.on('data', (d) => (ferr += d));
      ff.on('close', (fcode) => {
        downloads.delete(id);
        if (fcode === 0 && ok(out)) {
          try { fs.unlinkSync(src); } catch {}
          verifiedAudio.add(id);   // freshly transcoded to AAC-LC → known good
          resolve(out);
        } else {
          // Transcode failed — fall back to the original so the clip still plays
          // (may be silent, but better than nothing). Mark verified so we don't
          // re-download it on every request trying to "fix" an unfixable clip.
          try { fs.renameSync(src, out); } catch {}
          if (ok(out)) verifiedAudio.add(id);
          ok(out) ? resolve(out) : reject(new Error(`transcode failed (${fcode}): ${ferr.slice(-200)}`));
        }
      });
      ff.on('error', () => {
        downloads.delete(id);
        try { fs.renameSync(src, out); } catch {}
        if (ok(out)) verifiedAudio.add(id);
        ok(out) ? resolve(out) : reject(new Error('ffmpeg spawn failed'));
      });
    });
  });
  downloads.set(id, p);
  return p;
}

// Background prefetch with limited concurrency: warm upcoming clips ahead of time
// WITHOUT starving the clip the user is watching right now (that one is fetched
// on-demand and ungated). The audio transcode is CPU-bound, so kicking off too
// many at once just makes everything — including the current video — slower.
const PREFETCH_CONCURRENCY = 2;
let prefetchActive = 0;
const prefetchQueue = [];

function queuePrefetch(id) {
  const out = localFileFor(id);
  if ((fs.existsSync(out) && fs.statSync(out).size > 0) || downloads.has(id)) return;
  if (prefetchQueue.includes(id)) return;
  prefetchQueue.push(id);
  drainPrefetch();
}

function drainPrefetch() {
  while (prefetchActive < PREFETCH_CONCURRENCY && prefetchQueue.length) {
    const id = prefetchQueue.shift();
    prefetchActive++;
    ensureLocalFile(id)
      .catch(() => {})
      .finally(() => { prefetchActive--; drainPrefetch(); });
  }
}

// Warm the next few clips ahead of the one being watched so scrolling stays smooth.
function prefetchAround(id) {
  const data = feedCache.data || [];
  const i = data.findIndex((it) => it.id === id);
  if (i < 0) return;
  data.slice(i + 1, i + 5).forEach((it) => queuePrefetch(it.id));   // warm next 4
}

// ---- tiny in-memory caches ----
let feedCache = { ts: 0, data: null };
const videoCache = new Map(); // id -> { ts, item }
const commentsCache = new Map(); // id -> { ts, data }
const userCache = new Map(); // username -> { ts, data }
let moreBuffer = null; // Promise<items[]> for the next batch, prefetched in the background

// Start fetching the next batch ahead of time (only one in flight).
function primeMore() {
  if (moreBuffer) return;
  moreBuffer = getFeedItems().catch(() => null);
}

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
//    by /api/stream. This is the big speedup.
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

    // Fresh batch for infinite scroll — served from the prefetched buffer so
    // there's no wait at the boundary; immediately starts prefetching the next.
    if (url.pathname === '/api/more') {
      primeMore();
      const items = (await moreBuffer) || [];
      moreBuffer = null;
      primeMore(); // begin the batch after this one
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
      const cached = userCache.get('p:' + username);
      if (cached && Date.now() - cached.ts < FEED_TTL_MS) {
        return send(res, 200, cached.data);
      }
      const data = await fetchProfile(username, 30);
      userCache.set('p:' + username, { ts: Date.now(), data });
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

    // Read-only comments for a video.
    if (url.pathname.startsWith('/api/comments/')) {
      const id = url.pathname.split('/').pop();
      const cached = commentsCache.get(id);
      if (cached && Date.now() - cached.ts < FEED_TTL_MS) {
        return send(res, 200, { comments: cached.data });
      }
      const item = await getResolved(id);
      const vurl = `https://www.tiktok.com/@${item.author || '_'}/video/${id}`;
      const comments = await fetchComments(vurl, 20);
      commentsCache.set(id, { ts: Date.now(), data: comments });
      return send(res, 200, { comments });
    }

    // Stream proxy: the Apple TV plays this. yt-dlp downloads the clip, then we
    // serve it with HTTP Range support so AVPlayer can stream/seek smoothly.
    if (url.pathname.startsWith('/api/stream/')) {
      const id = url.pathname.split('/').pop().replace(/[^\w-]/g, '');
      prefetchAround(id); // warm the next few clips in the background
      const file = await ensureLocalFile(id);
      const size = fs.statSync(file).size;
      const range = req.headers.range;

      if (range) {
        const m = /bytes=(\d+)-(\d*)/.exec(range);
        const start = m ? parseInt(m[1], 10) : 0;
        const end = m && m[2] ? parseInt(m[2], 10) : size - 1;
        res.writeHead(206, {
          'Content-Type': 'video/mp4',
          'Accept-Ranges': 'bytes',
          'Content-Range': `bytes ${start}-${end}/${size}`,
          'Content-Length': end - start + 1,
        });
        fs.createReadStream(file, { start, end }).pipe(res);
      } else {
        res.writeHead(200, {
          'Content-Type': 'video/mp4',
          'Accept-Ranges': 'bytes',
          'Content-Length': size,
        });
        fs.createReadStream(file).pipe(res);
      }
      return;
    }

    send(res, 404, { error: 'not found' });
  } catch (e) {
    send(res, 500, { error: String(e).slice(0, 200) });
  }
});

// Delete cached clips older than an hour so the temp dir doesn't grow forever.
function cleanupTemp() {
  const dir = os.tmpdir();
  for (const f of fs.readdirSync(dir)) {
    if (!f.startsWith('tt-') || !f.endsWith('.mp4')) continue;
    const fp = path.join(dir, f);
    try {
      if (Date.now() - fs.statSync(fp).mtimeMs > 60 * 60 * 1000) fs.unlinkSync(fp);
    } catch {}
  }
}
cleanupTemp();
setInterval(cleanupTemp, 30 * 60 * 1000).unref();

// How many clips to fully download on startup before declaring "ready".
const PREWARM_COUNT = Number(process.env.PREWARM_COUNT || 10);

// Download a list of ids with limited concurrency, reporting progress.
async function prewarmClips(ids, concurrency, onProgress) {
  let next = 0, done = 0;
  async function worker() {
    while (next < ids.length) {
      const id = ids[next++];
      try { await ensureLocalFile(id); } catch {}
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
