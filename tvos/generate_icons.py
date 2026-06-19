"""Generate an original tvOS Brand Assets icon set (no third-party logos).
Run once: python generate_icons.py  -> creates Resources/Assets.xcassets
"""
import json
import os
from PIL import Image, ImageDraw

BASE = os.path.join(os.path.dirname(__file__), "Resources", "Assets.xcassets")
INFO = {"author": "xcode", "version": 1}


def wjson(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)


def make_png(w, h, path):
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):  # dark vertical gradient (row-by-row = fast)
        t = y / max(h - 1, 1)
        d.line([(0, y), (w, y)], fill=(int(22 - 14 * t), int(22 - 14 * t), int(26 - 16 * t)))
    s = min(w, h) * 0.30  # centered white "play" triangle (original mark)
    cx, cy = w / 2, h / 2
    d.polygon([(cx - s * 0.45, cy - s * 0.6),
               (cx - s * 0.45, cy + s * 0.6),
               (cx + s * 0.68, cy)], fill=(255, 255, 255))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)


def imagestack(name, sizes):
    """sizes: list of (w,h,scale) for the single layer's imageset."""
    stack = os.path.join(BASE, "App Icon & Top Shelf Image.brandassets", name)
    wjson(os.path.join(stack, "Contents.json"),
          {"info": INFO, "layers": [{"filename": "Front.imagestacklayer"}]})
    layer = os.path.join(stack, "Front.imagestacklayer")
    wjson(os.path.join(layer, "Contents.json"), {"info": INFO})
    content = os.path.join(layer, "Content.imageset")
    images = []
    for (w, h, scale) in sizes:
        fn = f"icon_{w}x{h}.png"
        make_png(w, h, os.path.join(content, fn))
        images.append({"idiom": "tv", "filename": fn, "scale": scale})
    wjson(os.path.join(content, "Contents.json"), {"images": images, "info": INFO})


def imageset(name, sizes):
    iset = os.path.join(BASE, "App Icon & Top Shelf Image.brandassets", name)
    images = []
    for (w, h, scale) in sizes:
        fn = f"img_{w}x{h}.png"
        make_png(w, h, os.path.join(iset, fn))
        images.append({"idiom": "tv", "filename": fn, "scale": scale})
    wjson(os.path.join(iset, "Contents.json"), {"images": images, "info": INFO})


# top-level catalog
wjson(os.path.join(BASE, "Contents.json"), {"info": INFO})

# brand assets manifest
wjson(os.path.join(BASE, "App Icon & Top Shelf Image.brandassets", "Contents.json"), {
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
