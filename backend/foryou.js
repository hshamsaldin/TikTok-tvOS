import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PYTHON } from './config.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const SCRIPT = path.join(here, 'auth', 'fetch_foryou.py');

// Returns the personalized For-You list as [{ id, url }] using the saved
// logged-in session. Throws if not logged in or the fetch fails.
export function fetchForYou(count) {
  return new Promise((resolve, reject) => {
    const child = spawn(PYTHON, [SCRIPT, String(count)], { windowsHide: true });
    let out = '';
    let err = '';
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (err += d));
    child.on('error', reject);
    child.on('close', (code) => {
      if (code !== 0) {
        return reject(new Error(`for-you fetch failed: ${err.slice(-300)}`));
      }
      try {
        resolve(JSON.parse(out));
      } catch {
        reject(new Error(`for-you JSON parse failed: ${err.slice(-300)}`));
      }
    });
  });
}
