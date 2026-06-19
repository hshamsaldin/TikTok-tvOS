# Running the backend on a Raspberry Pi (or any Linux box)

The backend is Node + Python (yt-dlp + headless Chromium). It must be **always on**
and on the **same network** as the Apple TV. A Pi 5 is ideal; a Pi 4 works but the
browser scrape is slower. Use a **64-bit OS** (Raspberry Pi OS 64-bit / Ubuntu) —
Playwright's Chromium needs arm64.

## 1. Install dependencies

```bash
# Node 20 (NodeSource)
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# Python + ffmpeg
sudo apt-get install -y python3 python3-pip ffmpeg

# Python packages
pip3 install -U yt-dlp playwright curl_cffi --break-system-packages

# Chromium for Playwright (+ its system libs)
python3 -m playwright install --with-deps chromium
```

## 2. Copy the project

Copy the `backend/` folder to the Pi, e.g. `/home/pi/tiktok-appletv/backend`.
(There are no native build steps — it's plain JS/Python.)

## 3. Add your login

Put your TikTok `sessionid` (from a logged-in browser — see main README) into:

```
/home/pi/tiktok-appletv/backend/auth/sessionid.txt
```

## 4. Test it

```bash
cd /home/pi/tiktok-appletv/backend
FEED_MODE=foryou node server.js
# open http://<pi-ip>:8787/ in a browser on the same network
```

`ffmpeg` is found on PATH automatically (no imageio-ffmpeg needed). `python3` and
`yt-dlp` are auto-detected. Chromium runs headless with `--no-sandbox`.

## 5. Run it 24/7 (systemd)

Edit `deploy/tiktok-appletv.service` (paths/user), then:

```bash
sudo cp deploy/tiktok-appletv.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now tiktok-appletv
sudo systemctl status tiktok-appletv     # check it's running
journalctl -u tiktok-appletv -f          # live logs
```

It now starts on boot and restarts on crash.

## 6. Point the app at the Pi

In `tvos/Sources/Config.swift`, set `backendBaseURL` to the Pi's LAN IP, e.g.
`http://192.168.1.50:8787`. Give the Pi a **static IP / DHCP reservation** so it
doesn't change.

## Notes
- **Pi 4 vs 5:** the For-You scrape is ~14s on a fast PC; expect ~25–40s on a Pi 4,
  less on a Pi 5. The double-buffering (prefetching the next batch) hides most of it.
- **sessionid expires** every so often — when the feed goes anonymous, refresh
  `sessionid.txt` with a new value.
- **Performance:** one viewer is fine on a Pi. It's not built for many at once.
