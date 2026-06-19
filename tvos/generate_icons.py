"""Generate an original tvOS Brand Assets icon set (no third-party logos).
Run once: python generate_icons.py  -> creates Resources/Assets.xcassets

tvOS app-icon imagestacks need >= 2 layers, so each icon stack has a Back
(gradient) layer and a Front (white play mark, transparent) layer.
"""
import json
import os
from PIL import Image, ImageDraw

BASE = os.path.join(os.path.dirname(__file__), "Resources", "Assets.xcassets")
BRAND = os.path.join(BASE, "App Icon & Top Shelf Image.brandassets")
INFO = {"author": "xcode", "version": 1}


def wjson(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)


def _save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)


def make_bg(w, h, path):  # opaque dark gradient
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(h - 1, 1)
        d.line([(0, y), (w, y)], fill=(int(22 - 14 * t), int(22 - 14 * t), int(26 - 16 * t)))
    _save(img, path)


def _triangle(d, w, h, rgba):
    s = min(w, h) * 0.30
    cx, cy = w / 2, h / 2
    d.polygon([(cx - s * 0.45, cy - s * 0.6),
               (cx - s * 0.45, cy + s * 0.6),
               (cx + s * 0.68, cy)], fill=rgba)


def make_front(w, h, path):  # transparent + white play mark
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    _triangle(ImageDraw.Draw(img), w, h, (255, 255, 255, 255))
    _save(img, path)


def make_flat(w, h, path):  # opaque gradient + play mark (for top-shelf imagesets)
    make_bg(w, h, path)
    img = Image.open(path).convert("RGB")
    _triangle(ImageDraw.Draw(img), w, h, (255, 255, 255))
    _save(img, path)


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

print("done ->", BASE)
