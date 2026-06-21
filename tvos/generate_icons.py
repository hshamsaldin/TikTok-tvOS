"""Generate the tvOS Brand Assets icon set: the TikTok note rendered straight from
its SVG path (no external image needed) — white with the cyan/red chromatic split,
centered on black. tvOS imagestacks need >= 2 layers, so each stack is a black Back
layer + the note on a transparent Front layer (parallax depth).

Run: python generate_icons.py
"""
import json
import os
import re
from PIL import Image, ImageDraw

HERE = os.path.dirname(__file__)
BASE = os.path.join(HERE, "Resources", "Assets.xcassets")
BRAND = os.path.join(BASE, "App Icon & Top Shelf Image.brandassets")
INFO = {"author": "xcode", "version": 1}

# The TikTok note, viewBox 0 0 24 24 (single closed path).
NOTE_PATH = ("M12.525.02c1.31-.02 2.61-.01 3.91-.02.08 1.53.63 3.09 1.75 4.17 1.12 "
             "1.11 2.7 1.62 4.24 1.79v4.03c-1.44-.05-2.89-.35-4.2-.97-.57-.26-1.1-.59"
             "-1.62-.93-.01 2.92.01 5.84-.02 8.75-.08 1.4-.54 2.79-1.35 3.94-1.31 1.92"
             "-3.58 3.17-5.91 3.21-1.43.08-2.86-.31-4.08-1.03-2.02-1.19-3.44-3.37-3.65"
             "-5.71-.02-.5-.03-1-.01-1.49.18-1.9 1.12-3.72 2.58-4.96 1.66-1.44 3.98-2.13"
             " 6.15-1.72.02 1.48-.04 2.96-.04 4.44-.99-.32-2.15-.23-3.02.37-.63.41-1.11"
             " 1.04-1.36 1.75-.21.51-.15 1.07-.14 1.61.24 1.64 1.82 3.02 3.5 2.87 1.12"
             "-.01 2.19-.66 2.77-1.61.19-.33.4-.67.41-1.06.1-1.79.06-3.57.07-5.36.01"
             "-4.03-.01-8.05.02-12.07z")


def _flatten(d, steps=20):
    """Flatten an SVG path (M/c/v/l/h/z, abs+rel) into polygon points."""
    toks = re.findall(r"[MmCcVvLlHhZz]|[-+]?(?:\d*\.\d+|\d+)", d)
    pts, i, cx, cy, sx, sy, cmd = [], 0, 0.0, 0.0, 0.0, 0.0, ""

    def nxt():
        nonlocal i
        v = float(toks[i]); i += 1; return v

    while i < len(toks):
        if re.match(r"[A-Za-z]", toks[i]):
            cmd = toks[i]; i += 1
            if cmd in "Zz":
                pts.append((sx, sy)); continue
        if cmd in "Mm":
            x, y = nxt(), nxt()
            if cmd == "m": x, y = cx + x, cy + y
            cx, cy, sx, sy = x, y, x, y; pts.append((cx, cy)); cmd = "Ll" and ("l" if cmd == "m" else "L")
        elif cmd in "Cc":
            c1x, c1y, c2x, c2y, x, y = (nxt() for _ in range(6))
            if cmd == "c":
                c1x, c1y, c2x, c2y, x, y = cx+c1x, cy+c1y, cx+c2x, cy+c2y, cx+x, cy+y
            for s in range(1, steps + 1):
                t = s / steps; m = 1 - t
                bx = m*m*m*cx + 3*m*m*t*c1x + 3*m*t*t*c2x + t*t*t*x
                by = m*m*m*cy + 3*m*m*t*c1y + 3*m*t*t*c2y + t*t*t*y
                pts.append((bx, by))
            cx, cy = x, y
        elif cmd in "Vv":
            y = nxt(); cy = cy + y if cmd == "v" else y; pts.append((cx, cy))
        elif cmd in "Hh":
            x = nxt(); cx = cx + x if cmd == "h" else x; pts.append((cx, cy))
        elif cmd in "Ll":
            x, y = nxt(), nxt()
            if cmd == "l": x, y = cx + x, cy + y
            cx, cy = x, y; pts.append((cx, cy))
        else:
            i += 1
    return pts


_POLY = _flatten(NOTE_PATH)


def _render_note(px):
    """The note (chromatic) on transparency, fitted into a px-square image."""
    ss = 4
    size = px * ss
    xs = [p[0] for p in _POLY]; ys = [p[1] for p in _POLY]
    w, h = max(xs) - min(xs), max(ys) - min(ys)
    pad = 0.10
    scale = size * (1 - 2 * pad) / max(w, h)
    ox = size * pad - min(xs) * scale + (size * (1 - 2 * pad) - w * scale) / 2
    oy = size * pad - min(ys) * scale + (size * (1 - 2 * pad) - h * scale) / 2
    poly = [(x * scale + ox, y * scale + oy) for x, y in _POLY]
    off = max(2, int(size * 0.013))
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    for dx, color in [(-off, (37, 244, 238, 255)),   # cyan, left
                      (off, (254, 44, 85, 255)),     # red, right
                      (0, (255, 255, 255, 255))]:     # white, center
        layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        ImageDraw.Draw(layer).polygon([(x + dx, y) for x, y in poly], fill=color)
        img = Image.alpha_composite(img, layer)
    return img.resize((px, px), Image.LANCZOS)


def wjson(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)


def _save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)


def _paste_note(canvas, scale):
    cw, ch = canvas.size
    s = int(min(cw, ch) * scale)
    canvas.alpha_composite(_render_note(s), ((cw - s) // 2, (ch - s) // 2))


def make_bg(w, h, path):                 # solid black (system rounds the corners)
    _save(Image.new("RGBA", (w, h), (0, 0, 0, 255)), path)


def make_front(w, h, path):              # note on transparency (icon Front layer)
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    _paste_note(img, 0.62)
    _save(img, path)


def make_flat(w, h, path):               # black + note (top-shelf imagesets)
    img = Image.new("RGBA", (w, h), (0, 0, 0, 255))
    _paste_note(img, 0.52)
    _save(img.convert("RGB"), path)


def imagestack(name, sizes):
    stack = os.path.join(BRAND, name)
    wjson(os.path.join(stack, "Contents.json"),
          {"info": INFO, "layers": [{"filename": "Front.imagestacklayer"},
                                     {"filename": "Back.imagestacklayer"}]})
    for layer, maker in [("Front.imagestacklayer", make_front),
                         ("Back.imagestacklayer", make_bg)]:
        wjson(os.path.join(stack, layer, "Contents.json"), {"info": INFO})
        content = os.path.join(stack, layer, "Content.imageset")
        images = []
        for (w, h, scale) in sizes:
            fn = f"{w}x{h}.png"
            maker(w, h, os.path.join(content, fn))
            images.append({"idiom": "tv", "filename": fn, "scale": scale})
        wjson(os.path.join(content, "Contents.json"), {"images": images, "info": INFO})


def imageset(name, sizes):
    iset = os.path.join(BRAND, name)
    images = []
    for (w, h, scale) in sizes:
        fn = f"{w}x{h}.png"
        make_flat(w, h, os.path.join(iset, fn))
        images.append({"idiom": "tv", "filename": fn, "scale": scale})
    wjson(os.path.join(iset, "Contents.json"), {"images": images, "info": INFO})


def make_logo_mark(w, h, path):          # just the note, on transparency, no black square —
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))   # for in-app use (e.g. the loading screen),
    _paste_note(img, 0.92)                            # NOT the app-icon brandassets catalog,
    _save(img, path)                                   # which SwiftUI's Image(_:) can't load from.


def plain_imageset(name, sizes, maker):
    iset = os.path.join(BASE, f"{name}.imageset")
    images = []
    for (w, h, scale) in sizes:
        fn = f"{name}@{scale}.png" if scale != "1x" else f"{name}.png"
        maker(w, h, os.path.join(iset, fn))
        images.append({"idiom": "universal", "filename": fn, "scale": scale})
    wjson(os.path.join(iset, "Contents.json"), {"images": images, "info": INFO})


wjson(os.path.join(BASE, "Contents.json"), {"info": INFO})
wjson(os.path.join(BRAND, "Contents.json"), {
    "assets": [
        {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
        {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
        {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
    ],
    "info": INFO,
})

imagestack("App Icon.imagestack", [(400, 240, "1x"), (800, 480, "2x")])
imagestack("App Icon - App Store.imagestack", [(1280, 768, "1x")])
imageset("Top Shelf Image.imageset", [(1920, 720, "1x"), (3840, 1440, "2x")])
imageset("Top Shelf Image Wide.imageset", [(2320, 720, "1x"), (4640, 1440, "2x")])
plain_imageset("LogoMark", [(240, 240, "1x"), (480, 480, "2x")], make_logo_mark)

print("done ->", BASE)
