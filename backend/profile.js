import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PYTHON } from './config.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.join(here, 'auth', 'fetch_profile.py');

// Fetch a channel's profile (header + video grid).
export function fetchProfile(username, count) {
  return new Promise((resolve, reject) => {
    const child = spawn(PYTHON, [SCRIPT, username, String(count)], {
      windowsHide: true,
      env: { ...process.env, PYTHONIOENCODING: 'utf-8' },
    });
    let out = '';
    let err = '';
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (err += d));
    child.on('error', reject);
    child.on('close', (code) => {
      if (code !== 0) return reject(new Error(`profile failed: ${err.slice(-200)}`));
      try {
        resolve(JSON.parse(out));
      } catch {
        reject(new Error(`profile parse failed: ${err.slice(-200)}`));
      }
    });
  });
}
