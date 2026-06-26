import { spawn } from 'node:child_process';
import { YTDLP_CMD, YTDLP_ARGS_PREFIX, YTDLP_IMPERSONATE } from './config.js';
import { throttleYtdlp } from './rateLimit.js';

// Run yt-dlp with the given args, capture stdout, parse as JSON.
async function runJson(args) {
  await throttleYtdlp();
  return new Promise((resolve, reject) => {
    const child = spawn(YTDLP_CMD, [...YTDLP_ARGS_PREFIX, ...YTDLP_IMPERSONATE, ...args], {
      windowsHide: true,
    });
    let out = '';
    let err = '';
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (err += d));
    child.on('error', reject);
    child.on('close', (code) => {
      if (code !== 0 && !out.trim()) {
        return reject(new Error(`yt-dlp exited ${code}: ${err.slice(-400)}`));
      }
      try {
        resolve(JSON.parse(out));
      } catch (e) {
        reject(new Error(`yt-dlp JSON parse failed: ${err.slice(-400)}`));
      }
    });
  });
}

// List a playlist (user / hashtag) without resolving each video — fast.
// Returns [{ id, url, title }]
export async function listSource(url, limit) {
  const data = await runJson([
    '--flat-playlist',
    '--playlist-end', String(limit),
    '-J',
    url,
  ]);
  const entries = data.entries || [];
  return entries
    .filter((e) => e && e.id)
    .map((e) => ({
      id: e.id,
      url: e.url || `https://www.tiktok.com/@_/video/${e.id}`,
      title: e.title || '',
    }));
}

// Pick the best directly-playable progressive MP4 from a format list.
// Returns null for photo/slideshow posts (no real video stream) so they get
// filtered out instead of falling back to a bare audio-track URL.
function pickPlayUrl(info) {
  const formats = (info.formats || []).filter(
    (f) =>
      f.url &&
      f.vcodec &&
      f.vcodec !== 'none' &&
      f.protocol === 'https' &&
      f.height // real video has dimensions; photo-mode audio does not
  );
  if (!formats.length) return null;
  // Prefer a non-watermarked format if available, else anything playable.
  const clean = formats.find((f) => !/watermark/i.test(f.format_note || ''));
  return (clean || formats[formats.length - 1]).url;
}

// List a slice of a user's videos for the profile grid (flat = fast, includes
// thumbnails + stats). `start` is 0-based.
export async function listUserGrid(username, start, count) {
  const data = await runJson([
    '--flat-playlist',
    '--playlist-start', String(start + 1),
    '--playlist-end', String(start + count),
    '--no-warnings',
    '-J',
    `https://www.tiktok.com/@${username}`,
  ]);
  return (data.entries || []).filter((e) => e && e.id).map((e) => {
    const thumbs = e.thumbnails || [];
    const artists = e.artists || [];
    return {
      id: e.id,
      author: e.uploader_id || e.uploader || username,
      nickname: e.uploader || e.channel || '',
      avatar: '',
      verified: false,
      caption: e.title || e.description || '',
      cover: thumbs.length ? thumbs[thumbs.length - 1].url : '',
      likes: e.like_count || 0,
      comments: e.comment_count || 0,
      shares: e.repost_count || 0,
      saves: e.save_count || 0,
      plays: e.view_count || 0,
      sound: e.track ? e.track + (artists[0] ? ' - ' + artists[0] : '') : '',
      soundCover: '',
    };
  });
}

// Fully resolve one video to a playable item.
// Returns { id, playUrl, author, caption, duration, cover, width, height }
export async function resolveVideo(url) {
  const info = await runJson(['-J', url]);
  // yt-dlp can exit 0 and print literal JSON `null` for some unextractable
  // posts (deleted, private, region/login-gated) instead of a non-zero exit
  // — that previously crashed the caller with a raw TypeError on `info.id`.
  if (!info) throw new Error(`yt-dlp returned no data for ${url}`);
  return {
    id: info.id,
    playUrl: pickPlayUrl(info),
    author: info.uploader || info.uploader_id || info.creator || '',
    nickname: info.uploader || info.creator || '',
    avatar: '',
    verified: false,
    caption: info.title || info.description || '',
    duration: info.duration || 0,
    cover: info.thumbnail || '',
    width: info.width || 0,
    height: info.height || 0,
    likes: info.like_count || 0,
    comments: info.comment_count || 0,
    shares: info.repost_count || 0,
    saves: 0,
    sound: [info.track, info.artist].filter(Boolean).join(' - '),
    soundCover: '',
  };
}
