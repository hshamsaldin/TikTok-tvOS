"""Generate the tvOS Brand Assets icon set from the real TikTok note.

Reads Resources/tiktok-icon-src.png (the square TikTok app icon), extracts the
note onto transparency, and composites it centered on black for the wide tvOS
icon frames. tvOS imagestacks need >= 2 layers, so each stack has a black Back
layer + the note on a transparent Front layer (gives the parallax depth).

Run: python generate_icons.py
"""
import json
import os
from PIL import Image

HERE = os.path.dirname(__file__)
BASE = os.path.join(HERE, "Resources", "Assets.xcassets")
BRAND = os.path.join(BASE, "App Icon & Top Shelf Image.brandassets")
SRC = os.path.join(HERE, "Resources", "tiktok-icon-src.png")
INFO = {"author": "xcode", "version": 1}


def wjson(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)


def _save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)


def _load_note():
    """The note on transparency: trim the rounded-square border, drop the black
    background, then crop to the note's bounding box."""
    im = Image.open(SRC).convert("RGBA")
    px = im.load()
    cw, ch = im.size
    for y in range(ch):
        for x in range(cw):
            r, g, b, _ = px[x, y]
            if max(r, g, b) < 50:         # black background → transparent
                px[x, y] = (0, 0, 0, 0)
    bbox = im.getbbox()
    return im.crop(bbox) if bbox else im


NOTE = _load_note()


def _paste_note(canvas, scale):
    cw, ch = canvas.size
    th = int(ch * scale)
    tw = int(NOTE.width * th / NOTE.height)
    note = NOTE.resize((tw, th), Image.LANCZOS)
    canvas.alpha_composite(note, ((cw - tw) // 2, (ch - th) // 2))


def make_bg(w, h, path):                 # solid black (system rounds the corners)
    _save(Image.new("RGBA", (w, h), (0, 0, 0, 255)), path)


def make_front(w, h, path):              # note on transparency (icon Front layer)
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    _paste_note(img, 0.82)
    _save(img, path)


def make_flat(w, h, path):               # black + note (top-shelf imagesets)
    img = Image.new("RGBA", (w, h), (0, 0, 0, 255))
    _paste_note(img, 0.70)
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
