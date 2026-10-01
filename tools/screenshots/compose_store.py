#!/usr/bin/env python3
"""Writes the Mac App Store screenshots of SimplyBar 1.1, in French, from the renderer's images.

Called by `make.sh --store` (read it first): the renderer, launched with --store, draws the real views of the app
(menu bar items, popups, widgets, the Diagnostic written by Apple's model) into a folder, then this script lays
out four pages of 2880 x 1800 into interne/appstore-screenshots-1.1/fr/. One series: a soft black with a faint blue
halo, one blue accent, a title in two beats (white, then blue), at most three short grey lines, the app's real views
floating at different depths. Each page has its own composition:

  01  the menu bar as a band on top, the title on the left, widgets on the right
  02  the title on top, the menu bar and the CPU popup on the right, the 1.0 widgets on the left
  03  Keep Awake: the cup, the popup and the widget on the left, the title on the right
  04  the Diagnostic: widgets top left, the popup on the right, the title at the bottom left

Run alone on a folder of an earlier run: python3 compose_store.py --root <repo> --assets <folder> [--only 02 03]
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compose import (APPSTORE_SIZE, FORBIDDEN_DASHES, MENUBAR_HEIGHT, Assets, lerp, load_font,  # noqa: E402
                     rounded_mask, save_png, scaled)

W, H = APPSTORE_SIZE
SF = "/System/Library/Fonts/SFNS.ttf"
NBSP = " "

# The 1.1 menu bar, left to right: the first item declared in SimplyBarApp.swift ends up rightmost. Health is hidden
# by default and stays out.
BAR_ORDER = ["keepAwake", "diagnostic", "bluetooth", "gpu", "disk", "network", "memory", "cpu"]

TITLES = [  # in two beats, white then blue
    "Votre Mac. En direct.",
    "Tout votre Mac. D’un coup d’œil.",
    "Pas de veille. Pas de pause.",
    "Votre Mac, expliqué. Par l’IA d’Apple.",
    "Il chauffe\u00a0? Vous le saurez.",
]


def fail(message: str) -> None:
    sys.exit(f"compose_store.py: {message}")


def check_text(text: str) -> None:
    """No long dash, and the French non-breaking space before : ? ! %."""
    for char, name in FORBIDDEN_DASHES.items():
        if char in text:
            fail(f"{name} in {text!r}")
    for index, char in enumerate(text):
        if char in ":?!%" and index > 0 and text[index - 1] != NBSP:
            fail(f"no non-breaking space before {char!r} in {text!r}")


# MARK: - Type

def font(weight: str, size: int):
    return load_font((SF, weight), size)


def text_width(face, text: str) -> float:
    return face.getlength(text)


def wrap(face, text: str, width: float) -> list[str]:
    """Greedy wrap on spaces; a non-breaking space never breaks."""
    lines, line = [], ""
    for word in text.split(" "):
        candidate = f"{line} {word}" if line else word
        if line and text_width(face, candidate) > width:
            lines.append(line)
            line = word
        else:
            line = candidate
    if line:
        lines.append(line)
    return lines


def write(canvas: Image.Image, xy, text: str, face, fill, width: float | None = None, leading: float = 1.12,
          shadow: int = 0, anchor_right: bool = False) -> float:
    """Writes `text` from its top left corner, wrapped to `width`; returns the y under the last line."""
    check_text(text)
    x, y = xy
    lines = wrap(face, text, width) if width else [text]
    ascent, descent = face.getmetrics()
    step = round((ascent + descent) * leading)
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    for index, line in enumerate(lines):
        lx = x - text_width(face, line) if anchor_right else x
        draw.text((lx, y + index * step), line, font=face, fill=fill)
    if shadow:
        blurred = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        blurred.putalpha(layer.getchannel("A").point(lambda value: round(value * 0.35)).filter(
            ImageFilter.GaussianBlur(shadow)))
        canvas.alpha_composite(blurred, (0, shadow // 2))
    canvas.alpha_composite(layer)
    return y + len(lines) * step


def fit_lines(text: str, weight: str, width: float, size: int, max_lines: int, minimum: int = 60):
    """The largest face, from `size` down, whose wrap of `text` takes at most `max_lines` lines."""
    while size >= minimum:
        face = font(weight, size)
        if len(wrap(face, text, width)) <= max_lines:
            return face
        size -= 4
    fail(f"title too long: {text!r}")


# MARK: - Backgrounds

def backdrop(top, bottom, blobs, size=APPSTORE_SIZE) -> Image.Image:
    """A smooth gradient with blurred colour shapes, drawn small then enlarged, as compose.wallpaper does."""
    width, height = size
    sw, sh = max(96, width // 10), max(60, height // 10)
    image = Image.new("RGB", (sw, sh))
    pixels = image.load()
    for y in range(sh):
        for x in range(sw):
            pixels[x, y] = lerp(top, bottom, min(1.0, max(0.0, 0.75 * y / sh + 0.3 * x / sw)))
    layer = Image.new("RGBA", (sw, sh), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    for cx, cy, r, colour, alpha in blobs:
        radius = r * sw
        draw.ellipse((cx * sw - radius, cy * sh - radius * 0.8, cx * sw + radius, cy * sh + radius * 0.8),
                     fill=colour + (alpha,))
    layer = layer.filter(ImageFilter.GaussianBlur(sw * 0.1))
    image = Image.alpha_composite(image.convert("RGBA"), layer).convert("RGB")
    return image.filter(ImageFilter.GaussianBlur(1.2)).resize((width, height), Image.BICUBIC).convert("RGBA")


ACCENT_ON_DARK = (72, 150, 255)  # the blue of the app icon, lightened for the dark pages: the one accent


GLOW_PAD = 260


def glowing(glyph: Image.Image) -> Image.Image:
    """A template glyph of the app (black on transparent) lit in the accent blue: lighter on top, with a soft halo."""
    size = (glyph.width + 2 * GLOW_PAD, glyph.height + 2 * GLOW_PAD)
    shape = Image.new("L", size, 0)
    shape.paste(glyph.getchannel("A"), (GLOW_PAD, GLOW_PAD))
    out = Image.new("RGBA", size, (0, 0, 0, 0))
    for blur, color, strength in [(110, (30, 100, 255), 0.55), (36, (80, 160, 255), 0.55), (10, (130, 190, 255), 0.5)]:
        halo = Image.new("RGBA", size, color + (0,))
        halo.putalpha(shape.filter(ImageFilter.GaussianBlur(blur)).point(lambda value: round(value * strength)))
        out.alpha_composite(halo)
    top, bottom = (170, 214, 255), ACCENT_ON_DARK
    fill = Image.new("RGBA", size)
    for y in range(size[1]):
        t = min(1, max(0, (y - GLOW_PAD) / max(1, glyph.height)))
        fill.paste(lerp(top, bottom, t) + (255,), (0, y, size[0], y + 1))
    fill.putalpha(shape)
    out.alpha_composite(fill)
    return out


def catalog_fr(root: Path, key: str) -> str:
    """The French text of the app for `key`, from its String Catalog."""
    strings = json.loads((root / "Shared" / "Localizable.xcstrings").read_text())["strings"]
    try:
        return strings[key]["localizations"]["fr"]["stringUnit"]["value"]
    except KeyError:
        fail(f"no French text for {key!r} in the String Catalog")


def notification(root: Path, title: str, body: str, when: str, k: float) -> Image.Image:
    """A macOS notification banner of the app, drawn after the system one in light mode: the app icon on the left,
    the title in bold with the time on its right, the body under it, on a light rounded material."""
    width, pad, gap, side = round(344 * k), round(14 * k), round(10 * k), round(36 * k)
    bold, regular, small = font("Bold", round(13 * k)), font("Regular", round(13 * k)), font("Regular", round(12 * k))
    text_x = pad + side + gap
    lines = wrap(regular, body, width - text_x - pad)
    ascent, descent = regular.getmetrics()
    step = round((ascent + descent) * 1.08)
    height = pad + step + len(lines) * step + pad
    card = Image.new("RGBA", (width, height), (238, 239, 243, 255))
    icon = Image.open(root / "SimplyBar" / "Assets.xcassets" / "AppIcon.appiconset" / "icon_512x512.png")
    icon = icon.convert("RGBA").resize((side, side), Image.LANCZOS)
    card.alpha_composite(icon, (pad, (height - side) // 2))
    write(card, (text_x, pad), title, bold, (20, 20, 22, 255))
    write(card, (width - pad, pad + round(1 * k)), when, small, (120, 120, 128, 255), anchor_right=True)
    write(card, (text_x, pad + step), body, regular, (40, 40, 44, 255), width=width - text_x - pad, leading=1.08)
    edge = ImageDraw.Draw(card)
    radius = round(18 * k)
    edge.rounded_rectangle((0, 0, width - 1, height - 1), radius, outline=(255, 255, 255, 140), width=2)
    card.putalpha(rounded_mask(card.size, radius))
    return card



def tile(image: Image.Image, k: float, radius_pt: float, fill) -> Image.Image:
    """A renderer image on its own opaque rounded card (a widget or a popup lifted off the desktop)."""
    picture = scaled(image, k)
    radius = round(radius_pt * k)
    card = Image.new("RGBA", picture.size, fill + (255,))
    card.alpha_composite(picture)
    edge = ImageDraw.Draw(card)
    edge.rounded_rectangle((0, 0, card.width - 1, card.height - 1), radius, outline=(0, 0, 0, 22), width=2)
    card.putalpha(rounded_mask(card.size, radius))
    return card


def float_on(canvas: Image.Image, card: Image.Image, xy, angle: float = 0, depth: int = 60, tint=(10, 14, 30),
             opacity: int = 120) -> None:
    """Pastes a card with its top left corner near `xy`, turned by `angle` degrees, over a soft shadow whose blur
    and offset grow with `depth` (the higher it floats, the larger and softer the shadow)."""
    turned = card.rotate(angle, resample=Image.BICUBIC, expand=True) if angle else card
    x, y = round(xy[0] - (turned.width - card.width) / 2), round(xy[1] - (turned.height - card.height) / 2)
    pad = depth * 3
    alpha = Image.new("L", (turned.width + 2 * pad, turned.height + 2 * pad), 0)
    alpha.paste(turned.getchannel("A").point(lambda value: round(value * opacity / 255)), (pad, pad))
    alpha = alpha.filter(ImageFilter.GaussianBlur(depth))
    shadow = Image.new("RGBA", alpha.size, tint + (0,))
    shadow.putalpha(alpha)
    canvas.alpha_composite(shadow, (x - pad, y - pad + depth // 2))
    canvas.alpha_composite(turned, (x, y))


def menubar_pill(assets: Assets, k: float, lit: str = "keepAwake", cup_on: bool = True) -> Image.Image:
    """The app's menu bar items alone, as a light pill at `k` pixels per point, one item lit as when it is open."""
    names = {"keepAwake": "menubar-keepAwake-on"} if cup_on else {}
    widths = [assets.points(names.get(module, f"menubar-{module}"))[0] + 14 for module in BAR_ORDER]
    pad = 12
    width, height = round((sum(widths) + 2 * pad) * k), round(MENUBAR_HEIGHT * 1.5 * k)
    pill = Image.new("RGBA", (width, height), (250, 250, 252, 255))
    x = pad
    for module, slot in zip(BAR_ORDER, widths):
        name = names.get(module, f"menubar-{module}")
        w, h = assets.points(name)
        if module == lit:
            # Drawn on its own layer: ImageDraw would replace the pixels instead of blending them.
            glow = Image.new("RGBA", pill.size, (0, 0, 0, 0))
            ImageDraw.Draw(glow).rounded_rectangle(
                (round((x + 1) * k), round((height / k - MENUBAR_HEIGHT + 4) / 2 * k), round((x + slot - 1) * k),
                 round((height / k + MENUBAR_HEIGHT - 4) / 2 * k)), round(6 * k), fill=(0, 0, 0, 26))
            pill.alpha_composite(glow)
        image = scaled(assets.get(name), k)
        pill.alpha_composite(image, (round((x + 7) * k), round((height / k - h) / 2 * k)))
        x += slot
    pill.putalpha(rounded_mask(pill.size, height // 2))
    return pill


def page_promise(assets: Assets) -> Image.Image:
    """01, dark: the app's menu bar enlarged as a floating band, one strong headline, three short titles, the
    widgets floating on the right at different depths. No paragraph."""
    canvas = backdrop((13, 14, 18), (18, 20, 28), [
        (0.78, 0.62, 0.32, (20, 70, 170), 110), (0.95, 0.15, 0.20, (30, 60, 120), 70),
    ])
    pill = menubar_pill(assets, 4.4)
    float_on(canvas, pill, ((W - pill.width) / 2, 120), depth=40, tint=(0, 0, 0), opacity=160)

    left = 170
    big = font("Heavy", 250)
    write(canvas, (left, 420), "Votre Mac.", big, (246, 247, 250, 255))
    write(canvas, (left, 690), "En direct.", big, ACCENT_ON_DARK + (255,))
    face = font("Bold", 84)
    y = 1110
    for line in ["Gardez-le éveillé.", "L’IA d’Apple, sur votre Mac.", "Gratuit et libre."]:
        y = write(canvas, (left, y), line, face, (196, 200, 212, 255)) + 26

    k = 3.0
    white = (252, 252, 253)
    float_on(canvas, tile(assets.get("widget-memory"), k, 22, white), (2330, 330), angle=7, depth=50, tint=(0, 0, 0))
    float_on(canvas, tile(assets.get("widget-diagnostic-medium"), k, 22, white), (1560, 560), angle=-3, depth=70,
             tint=(0, 0, 0))
    float_on(canvas, tile(assets.get("widget-cpu"), k, 22, white), (1640, 1140), angle=4, depth=60, tint=(0, 0, 0))
    float_on(canvas, tile(assets.get("widget-keepAwake"), k, 22, white), (2200, 1120), angle=-5, depth=80,
             tint=(0, 0, 0))
    return canvas


WHITE, GREY = (246, 247, 250), (196, 200, 212)


def dark(halos) -> Image.Image:
    """The background of the series: a soft black with a faint blue halo where the app's views float."""
    return backdrop((13, 14, 18), (18, 20, 28), halos)


def headline(canvas: Image.Image, x: float, y: float, first: str, second: str, width: float, size: int,
             greys: tuple[str, ...] = (), grey_size: int = 80) -> float:
    """The title in two beats, white then blue, each on one line, then up to three short grey lines."""
    face = min((fit_lines(text, "Heavy", width, size, 1) for text in (first, second)), key=lambda f: f.size)
    step = round(face.size * 1.08)
    write(canvas, (x, y), first, face, WHITE + (255,))
    y = write(canvas, (x, y + step), second, face, ACCENT_ON_DARK + (255,))
    if greys:
        y += round(grey_size * 0.5)
        small = font("Bold", grey_size)
        for line in greys:
            y = write(canvas, (x, y), line, small, GREY + (255,)) + round(grey_size * 0.3)
    return y


def page_overview(assets: Assets) -> Image.Image:
    """02: the title on top; under it the app's menu bar enlarged, the CPU popup hanging from its item on the
    right, the widgets of version 1.0 floating on the left at different depths."""
    canvas = dark([(0.45, 0.80, 0.42, (20, 70, 170), 105), (0.90, 0.75, 0.25, (30, 60, 130), 70)])
    headline(canvas, 170, 100, "Tout votre Mac.", "D’un coup d’œil.", 2000, 200)

    pill = menubar_pill(assets, 4.0, lit="cpu", cup_on=False)
    pill_x, pill_y = W - 120 - pill.width, 640
    float_on(canvas, pill, (pill_x, pill_y), depth=40, tint=(0, 0, 0), opacity=160)
    cpu = tile(assets.get("popup-cpu"), 1.9, 14, (246, 246, 248))
    float_on(canvas, cpu, (W - 150 - cpu.width, pill_y + pill.height + 34), depth=60, tint=(0, 0, 0))

    k, white = 2.3, (252, 252, 253)
    for name, xy, angle, depth in [
        ("widget-storage-medium", (190, 880), -3, 50), ("widget-cpu", (1110, 860), 4, 60),
        ("widget-memory", (1560, 1050), -5, 80), ("widget-network", (380, 1290), 5, 70),
        ("widget-disk", (880, 1300), -3, 90),
    ]:
        float_on(canvas, tile(assets.get(name), k, 22, white), xy, angle=angle, depth=depth, tint=(0, 0, 0))
    return canvas


def page_keep_awake(assets: Assets) -> Image.Image:
    """03: the views on the left (the cup of the menu bar very large, lit in the accent, the popup, the widget), the
    title on the right."""
    canvas = dark([(0.25, 0.50, 0.40, (20, 70, 170), 110), (0.05, 0.10, 0.25, (30, 60, 130), 60)])
    cup = assets.get("menubar-keepAwake-on-large")  # drawn at 36 pixels per point, shown as is
    canvas.alpha_composite(glowing(cup), (470 - cup.width // 2 - GLOW_PAD, 430 - cup.height // 2 - GLOW_PAD))

    k = 2.6
    float_on(canvas, tile(assets.get("popup-keepAwake-display"), k, 14, (246, 246, 248)), (700, 720), angle=3,
             depth=70, tint=(0, 0, 0))
    float_on(canvas, tile(assets.get("widget-keepAwake"), k, 22, (252, 252, 253)), (1330, 1290), angle=-6,
             depth=90, tint=(0, 0, 0))

    x = 1700
    headline(canvas, x, 560, "Pas de veille.", "Pas de pause.", W - 130 - x, 190,
             greys=(f"De 30{NBSP}min à 4{NBSP}h, ou sans fin.", "L’écran aussi, si vous voulez."), grey_size=72)
    return canvas


def page_diagnostic(assets: Assets) -> Image.Image:
    """04: the Diagnostic widgets on the top left, the popup (card, question and answer by Apple's model) large on
    the right, the title at the bottom left."""
    canvas = dark([(0.80, 0.45, 0.40, (20, 70, 170), 110), (0.20, 0.20, 0.30, (30, 60, 130), 70)])
    float_on(canvas, tile(assets.get("popup-diagnostic"), 2.3, 14, (246, 246, 248)), (1880, 300), angle=3,
             depth=80, tint=(0, 0, 0))
    k, white = 2.5, (252, 252, 253)
    float_on(canvas, tile(assets.get("widget-diagnostic-medium"), k, 22, white), (170, 150), angle=-4, depth=50,
             tint=(0, 0, 0))
    float_on(canvas, tile(assets.get("widget-diagnostic-small"), k, 22, white), (1250, 380), angle=6, depth=70,
             tint=(0, 0, 0))
    headline(canvas, 170, 980, "Votre Mac, expliqué.", "Par l’IA d’Apple.", 1620, 190,
             greys=("Rien ne quitte votre Mac.",), grey_size=76)
    return canvas


def page_health(assets: Assets, root: Path) -> Image.Image:
    """05: the title centred on top, the heat alert of the app as macOS shows it under it, then the Health popup
    and widget floating on each side."""
    canvas = dark([(0.50, 0.45, 0.45, (20, 70, 170), 110), (0.15, 0.85, 0.30, (30, 60, 130), 60),
                   (0.85, 0.85, 0.30, (30, 60, 130), 60)])
    first, second = "Il chauffe\u00a0?", "Vous le saurez."
    face = min((fit_lines(text, "Heavy", 2200, 190, 1) for text in (first, second)), key=lambda f: f.size)
    step = round(face.size * 1.08)
    y = 110
    for text, color in [(first, WHITE), (second, ACCENT_ON_DARK)]:
        write(canvas, ((W - text_width(face, text)) / 2, y), text, face, color + (255,))
        y += step
    grey = "Chauffe, batterie et alertes."
    small = font("Bold", 72)
    write(canvas, ((W - text_width(small, grey)) / 2, y + 30), grey, small, GREY + (255,))

    float_on(canvas, tile(assets.get("popup-health"), 2.2, 14, (246, 246, 248)), (300, 800), angle=-4, depth=80,
             tint=(0, 0, 0))
    float_on(canvas, tile(assets.get("widget-health-medium"), 2.6, 22, (252, 252, 253)), (1580, 1160), angle=4,
             depth=70, tint=(0, 0, 0))
    banner = notification(root, catalog_fr(root, "Your Mac is hot"),
                          catalog_fr(root, "macOS slows the Mac down to cool it. Quit heavy apps and keep the vents "
                                           "clear."), "maintenant", 2.9)
    float_on(canvas, banner, (1310, 760), depth=60, tint=(0, 0, 0), opacity=150)
    return canvas


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", required=True)
    parser.add_argument("--assets", required=True, help="folder of a `Renderer --store` run")
    parser.add_argument("--only", nargs="+", choices=["01", "02", "03", "04", "05"], help="write only these pages")
    args = parser.parse_args()
    for title in TITLES:
        check_text(title)
    assets = Assets(Path(args.assets))
    out = Path(args.root) / "interne" / "appstore-screenshots-1.1" / "fr"
    root = Path(args.root)
    pages = [("01", page_promise), ("02", page_overview), ("03", page_keep_awake), ("04", page_diagnostic),
             ("05", lambda assets: page_health(assets, root))]
    for name, page in pages:
        if args.only and name not in args.only:
            continue
        image = page(assets)
        if image.size != APPSTORE_SIZE:
            fail(f"{name}: {image.size} instead of {APPSTORE_SIZE}")
        path = out / f"{name}.png"
        size = save_png(image, path)
        print(f"  {path.relative_to(Path(args.root))} {image.width}x{image.height} {size // 1024} KB")


if __name__ == "__main__":
    main()
