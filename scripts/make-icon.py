#!/usr/bin/env python3
"""Draws the Brain Input icon ("Text Brain": text lines whose lengths trace a brain, ending in a cursor).

Writes Assets/AppIcon-1024.png, Assets/AppIcon.icns (all macOS sizes) and the menu bar template images
Assets/MenuBarIcon.png, @2x, @3x. Needs Pillow and macOS `iconutil`. Run: scripts/make-icon.py
"""
import math, os, shutil, subprocess, tempfile
from PIL import Image, ImageDraw, ImageFilter, ImageChops

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
ASSETS = os.path.join(ROOT, "Assets")
SS = 2  # supersampling for the master

BG_TOP, BG_BOTTOM = (10, 68, 50), (38, 152, 106)   # deep green to mid green, diagonal
INK = (255, 255, 255)
CURSOR = (124, 240, 182)

# Brain from above: half-lengths of each text line, top to bottom.
# An oval (a brain from above is longer than it is wide), nine lines, with a little hand-made irregularity.
_RX, _N = 292, 9
HALF = [round(_RX * math.sqrt(1 - ((i - 4) / 4.6) ** 2) * j) for i, j in enumerate([1.0, 1.02, 0.98, 1.0, 1.01, 0.97, 1.0, 0.96, 0.98])]
PITCH, THICK, GAP, TOP = 62, 34, 18, 236


def squircle_mask(size, body, n=5.0):
    """macOS-style continuous-corner body: superellipse, `body` px across, centred."""
    m = Image.new("L", (size, size), 0)
    c, r = size / 2, body / 2
    pts = []
    for i in range(361):
        t = i / 360 * 2 * math.pi
        co, si = math.cos(t), math.sin(t)
        pts.append((c + r * math.copysign(abs(co) ** (2 / n), co), c + r * math.copysign(abs(si) ** (2 / n), si)))
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m


def gradient(size, c1, c2):
    a = Image.new("RGB", (size, size), c1)
    b = Image.new("RGB", (size, size), c2)
    ramp = Image.new("L", (size, size))
    px = ramp.load()
    for y in range(size):
        for x in range(size):
            px[x, y] = int(255 * (x + y) / (2 * (size - 1)))
    return Image.composite(b, a, ramp)


def rrect(d, x0, y0, x1, y1, fill, s):
    d.rounded_rectangle([x0 * s, y0 * s, x1 * s, y1 * s], radius=(y1 - y0) * s / 2, fill=fill)


def draw_glyph(img, s):
    d = ImageDraw.Draw(img, "RGBA")
    for i, h in enumerate(HALF):
        y = TOP + i * PITCH
        col = INK + (255,)
        rrect(d, 512 - h, y, 512 - GAP, y + THICK, col, s)
        if i < len(HALF) - 1:
            rrect(d, 512 + GAP, y, 512 + h, y + THICK, col, s)
        else:  # last line ends in a live cursor
            rrect(d, 512 - GAP + 14, y - 22, 512 - GAP + 14 + 30, y + THICK + 22, CURSOR + (255,), s)


def master():
    S = 1024 * SS
    body = 824 * SS
    mask = squircle_mask(S, body)
    bg = gradient(S, BG_TOP, BG_BOTTOM).convert("RGBA")
    bg.putalpha(mask)
    # soft top highlight
    hi = Image.linear_gradient("L").transpose(Image.FLIP_TOP_BOTTOM).resize((S, S))
    hi = hi.point(lambda v: int(max(0, v - 90) / 165 * 0.18 * 255)).convert("L")  # smooth, fades out before the middle
    hi = ImageChops.multiply(hi, mask)
    white = Image.new("RGBA", (S, S), (255, 255, 255, 0)); white.putalpha(hi)
    bg = Image.alpha_composite(bg, white)
    draw_glyph(bg, SS)
    # drop shadow under the body
    sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    a = mask.filter(ImageFilter.GaussianBlur(18 * SS)).point(lambda v: int(v * 0.38))
    sh.putalpha(a)
    sh = ImageChops.offset(sh, 0, 14 * SS)
    out = Image.alpha_composite(sh, bg)
    return out.resize((1024, 1024), Image.LANCZOS)


def menubar(px):
    """One-colour template glyph, simplified to 5 thicker lines so it holds up at 18 pt."""
    s = 8
    S = px * s
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    k = S / 800.0
    half = [230, 350, 390, 350, 190]
    th, pitch = 104, 160
    top = (800 - (4 * pitch + th)) / 2
    for i, h in enumerate(half):
        y = top + i * pitch
        L = (400 - h) * k, y * k, (400 - 30) * k, (y + th) * k
        d.rounded_rectangle(L, radius=th * k / 2, fill=(0, 0, 0, 255))
        if i < 4:
            d.rounded_rectangle(((400 + 30) * k, y * k, (400 + h) * k, (y + th) * k), radius=th * k / 2, fill=(0, 0, 0, 255))
        else:
            d.rounded_rectangle(((400 + 50) * k, (y - 40) * k, (400 + 50 + 72) * k, (y + th + 40) * k), radius=36 * k, fill=(0, 0, 0, 255))
    return img.resize((px, px), Image.LANCZOS)


def main():
    os.makedirs(ASSETS, exist_ok=True)
    m = master()
    m.save(os.path.join(ASSETS, "AppIcon-1024.png"))
    with tempfile.TemporaryDirectory() as t:
        iconset = os.path.join(t, "AppIcon.iconset")
        os.makedirs(iconset)
        for base in (16, 32, 128, 256, 512):
            m.resize((base, base), Image.LANCZOS).save(os.path.join(iconset, f"icon_{base}x{base}.png"))
            m.resize((base * 2, base * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{base}x{base}@2x.png"))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(ASSETS, "AppIcon.icns")], check=True)
    for scale, name in ((1, "MenuBarIcon.png"), (2, "MenuBarIcon@2x.png"), (3, "MenuBarIcon@3x.png")):
        menubar(18 * scale).save(os.path.join(ASSETS, name))
    # preview sheet for eyeballing: not shipped
    sheet = Image.new("RGBA", (1024 + 40, 1024 + 200), (236, 236, 240, 255))
    sheet.alpha_composite(m, (20, 20))
    x = 20
    for s in (128, 64, 32, 16):
        sheet.alpha_composite(m.resize((s, s), Image.LANCZOS), (x, 1060)); x += s + 20
    for scale, bgc, xx in ((3, (233, 235, 241, 255), 400), (3, (30, 31, 40, 255), 560)):
        tile = Image.new("RGBA", (130, 60), bgc)
        g = menubar(54)
        if bgc[0] < 100:
            g = Image.merge("RGBA", (*(Image.new("L", g.size, 245),) * 3, g.getchannel("A")))
        tile.alpha_composite(g, (38, 3)); sheet.alpha_composite(tile, (xx, 1060))
    sheet.save(os.path.join(tempfile.gettempdir(), "brain-input-icon-preview.png"))
    print("wrote", ASSETS, "| preview:", os.path.join(tempfile.gettempdir(), "brain-input-icon-preview.png"))


if __name__ == "__main__":
    main()
