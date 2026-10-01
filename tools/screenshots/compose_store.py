#!/usr/bin/env python3
"""Writes the Mac App Store screenshots of SimplyBar 1.1, in French, from the renderer's images.

Called by `make.sh --store` (read it first): the renderer, launched with --store, draws the real views of the app
(menu bar items, popups, widgets, the Diagnostic written by Apple's model) into a folder, then this script lays
out four different pages of 2880 x 1800 into interne/appstore-screenshots-1.1/fr/:

  01  no view of the app: the headline and what SimplyBar offers, set in type
  02  the version 1.0 overview: the whole menu bar, the CPU popup, the original widgets, full bleed
  03  Keep Awake: a zoomed corner of the desktop (item, popup, widget) on the right, the text on the left
  04  the Diagnostic: the title on top, the popup, both widgets and what stays on the Mac

The drawing helpers (desktop wallpaper, frosted panels, shadows, fonts) come from compose.py, which is not changed.
Run alone on a folder of an earlier run: python3 compose_store.py --root <repo> --assets <folder>
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parent))
import compose  # noqa: E402
from compose import (APPSTORE_SIZE, FORBIDDEN_DASHES, GRID_GAP_X, GRID_GAP_Y, LARGE, MENUBAR_HEIGHT, SMALL,  # noqa: E402
                     Assets, Desktop, drop_shadow, frosted, lerp, load_font, rounded_mask, save_png, scaled)

W, H = APPSTORE_SIZE
SF = "/System/Library/Fonts/SFNS.ttf"
NBSP = " "

# The 1.1 menu bar, left to right: the first item declared in SimplyBarApp.swift ends up rightmost. Health is hidden
# by default and stays out.
BAR_ORDER = ["keepAwake", "diagnostic", "bluetooth", "gpu", "disk", "network", "memory", "cpu"]

TITLES = [
    "Tout votre Mac, d’un coup d’œil",
    "Votre Mac en direct dans la barre des menus",
    f"Anti-veille{NBSP}: votre Mac reste éveillé",
    "Un diagnostic rédigé par l’IA d’Apple",
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


def glass(canvas: Image.Image, box, radius: int, tint, border, blur: float = 30, shadow: int = 0) -> None:
    if shadow:
        drop_shadow(canvas, box, radius, blur=shadow, offset=shadow // 2, opacity=90)
    frosted(canvas, box, radius, tint, blur, border=border)


# MARK: - Desktop pieces

def draw_bar(desk: Desktop, order: list[str], start: float | None = None, tray: bool = True,
             names: dict[str, str] | None = None) -> None:
    """The menu bar: right aligned next to the system tray as macOS lays it, or from `start` to the right (a
    zoomed corner of the screen). `names` swaps an item for another drawing (Keep Awake on)."""
    names = names or {}
    frosted(desk.image, (0, 0, desk.image.width, desk.px(MENUBAR_HEIGHT)), 0, (250, 250, 255, 105),
            9 * desk.k, border=None)
    if start is None:
        tray_w, tray_h = desk.assets.points("menubar-system")
        x = desk.width - 12 - tray_w
        if tray:
            desk.paste_template("menubar-system", x, (MENUBAR_HEIGHT - tray_h) / 2)
        x -= 10
        for module in reversed(order):
            w, h = desk.assets.points(names.get(module, f"menubar-{module}"))
            x -= w + 14
            desk.slots[module] = (x, w + 14)
            desk.paste_template(names.get(module, f"menubar-{module}"), x + 7, (MENUBAR_HEIGHT - h) / 2)
    else:
        x = start
        for module in order:
            w, h = desk.assets.points(names.get(module, f"menubar-{module}"))
            desk.slots[module] = (x, w + 14)
            desk.paste_template(names.get(module, f"menubar-{module}"), x + 7, (MENUBAR_HEIGHT - h) / 2)
            x += w + 14


def popup(desk: Desktop, name: str, x: float, y: float = MENUBAR_HEIGHT + 5) -> tuple[float, float]:
    """A popup window drawn as compose.Desktop.popup draws it, from any renderer image."""
    w, h = desk.assets.points(name)
    box = desk.box(x, y, w, h)
    radius = desk.px(14)
    drop_shadow(desk.image, box, radius, blur=desk.px(16), offset=desk.px(8), opacity=110)
    frosted(desk.image, box, radius, (246, 246, 248, 222), desk.px(20), border=(0, 0, 0, 28))
    desk.image.alpha_composite(scaled(desk.assets.get(name), desk.k), box[:2])
    return w, h


def card(canvas: Image.Image, image: Image.Image, xy, k: float, radius_pt: float, tint, border, shadow=True):
    """A renderer image at `k` pixels per point on a frosted card of the canvas (popups and widgets)."""
    picture = scaled(image, k)
    box = (round(xy[0]), round(xy[1]), picture.width, picture.height)
    radius = round(radius_pt * k)
    if shadow:
        drop_shadow(canvas, box, radius, blur=round(14 * k), offset=round(6 * k), opacity=95)
    frosted(canvas, box, radius, tint, 18 * k, border=border)
    canvas.alpha_composite(picture, box[:2])
    return picture.width, picture.height


# MARK: - The four pages

def page_promise(assets: Assets) -> Image.Image:
    """01: no view of the app, the promise in type. Headline on the left, six claims in a grid on the right,
    a band of four short facts along the bottom."""
    canvas = backdrop((10, 12, 34), (34, 18, 64), [
        (0.10, 0.20, 0.36, (70, 60, 220), 150), (0.85, 0.15, 0.30, (30, 150, 240), 120),
        (0.70, 0.85, 0.40, (200, 70, 160), 120), (0.05, 0.95, 0.30, (255, 140, 90), 90),
    ])
    left = 150
    write(canvas, (left, 250), "SimplyBar pour macOS", font("Semibold", 54), (170, 190, 255, 255))
    headline = font("Heavy", 150)
    y = write(canvas, (left, 340), TITLES[0], headline, (255, 255, 255, 255), width=1000, leading=1.06, shadow=12)
    write(canvas, (left, y + 50), "Vos mesures en direct, des widgets, un anti-veille et un diagnostic, "
          "dans une seule petite app.", font("Medium", 54), (214, 218, 240, 255), width=920, leading=1.25)

    claims = [
        ("CPU, RAM, GPU", "réseau et stockage dans la barre des menus", (120, 200, 255)),
        ("10 widgets", "pour garder vos mesures sous les yeux sur le bureau", (130, 230, 170)),
        ("Anti-veille", "Mac et écran gardés éveillés", (255, 196, 110)),
        ("Santé du Mac", "chauffe et batterie surveillées", (255, 130, 140)),
        ("Diagnostic", "rédigé par l’IA d’Apple, sur l’appareil", (196, 150, 255)),
        ("50 langues", "l’app parle la vôtre, du français au japonais", (110, 225, 230)),
    ]
    gx, gy, cw, ch, gap = 1230, 180, 710, 390, 36
    big, small = font("Heavy", 78), font("Medium", 44)
    for index, (head, line, colour) in enumerate(claims):
        column, row = index % 2, index // 2
        x, y0 = gx + column * (cw + gap), gy + row * (ch + gap)
        glass(canvas, (x, y0, cw, ch), 44, (255, 255, 255, 20), (255, 255, 255, 46), blur=26)
        accent = Image.new("RGBA", (10, 96), colour + (255,))
        canvas.paste(accent, (x + 54, y0 + 66), rounded_mask(accent.size, 5))
        write(canvas, (x + 92, y0 + 58), head, big, colour + (255,))
        write(canvas, (x + 92, y0 + 182), line, small, (226, 230, 246, 255), width=cw - 150, leading=1.22)

    facts = ["Gratuit", "Libre et open source", "Aucune donnée collectée"]
    face = font("Bold", 52)
    dot = "   •   "
    band = dot.join(facts)
    band_w = text_width(face, band)
    by = 1490
    glass(canvas, (left, by, W - 2 * left, 160), 80, (255, 255, 255, 26), (255, 255, 255, 60), blur=26)
    write(canvas, ((W - band_w) / 2, by + 46), band, face, (255, 255, 255, 255))
    return canvas


def page_overview(assets: Assets) -> Image.Image:
    """02: the desktop of version 1.0, full bleed: the whole menu bar, the CPU popup, the five original widgets,
    the title written on the wallpaper."""
    k = 2.4
    desk = Desktop(assets, W / k, H / k, k, False, menubar=False)
    draw_bar(desk, BAR_ORDER)
    width, height = desk.width, desk.height
    x_cpu = min(max(8, desk.slots["cpu"][0]), width - 300 - 10)
    desk.highlight("cpu")
    group_y = height - LARGE[1] - 44
    for index, name in enumerate(["cpu", "memory", "network", "disk"]):
        column, row = index % 2, index // 2
        desk.widget(name, 44 + column * (SMALL[0] + GRID_GAP_X), group_y + row * (SMALL[1] + GRID_GAP_Y))
    desk.widget("storage-large", 44 + LARGE[0] + GRID_GAP_X, group_y)
    popup(desk, "popup-cpu", x_cpu)
    canvas = desk.image
    y = write(canvas, (round(44 * k), round(62 * k)), TITLES[1], font("Heavy", 124), (255, 255, 255, 255),
          width=round((x_cpu - 90) * k), leading=1.05, shadow=16)
    write(canvas, (round(44 * k), y + 30), "CPU, RAM, GPU, réseau, SSD et Bluetooth. Un clic ouvre la fenêtre "
          "détaillée de chaque module.", font("Semibold", 54), (255, 255, 255, 235), width=round((x_cpu - 90) * k),
          leading=1.25, shadow=10)
    return canvas


def page_keep_awake(assets: Assets) -> Image.Image:
    """03: Keep Awake. The text on the left; on the right a zoomed corner of the desktop: the item lit in the
    menu bar, its popup open with the display kept on, the Keep Awake widget."""
    canvas = backdrop((14, 18, 46), (46, 30, 78), [
        (0.80, 0.55, 0.38, (255, 170, 80), 120), (0.15, 0.10, 0.30, (60, 80, 200), 130),
        (0.40, 0.95, 0.30, (150, 70, 170), 110),
    ])
    left = 150
    y = write(canvas, (left, 330), TITLES[2], font("Heavy", 128), (255, 255, 255, 255), width=1050,
              leading=1.06, shadow=12)
    points = [
        f"Indéfiniment, 30{NBSP}min, 1{NBSP}h, 2{NBSP}h ou 4{NBSP}h",
        "L’écran peut rester allumé lui aussi",
        "Le temps restant toujours affiché",
        "Un widget pour l’allumer d’un clic",
    ]
    face = font("Semibold", 58)
    y += 70
    for point in points:
        dot = Image.new("RGBA", (26, 26), (255, 196, 110, 255))
        canvas.paste(dot, (left, y + 26), rounded_mask(dot.size, 13))
        y = write(canvas, (left + 60, y), point, face, (232, 234, 248, 255), width=980) + 30

    # The zoomed corner: a desktop of its own, framed like a window onto the screen.
    k = 2.9
    frame = (1290, 180, 1440, 1440)
    desk = Desktop(assets, frame[2] / k, frame[3] / k, k, False, menubar=False)
    draw_bar(desk, BAR_ORDER, start=18, names={"keepAwake": "menubar-keepAwake-on"})
    desk.highlight("keepAwake")
    pop_w, pop_h = popup(desk, "popup-keepAwake-display", 14)
    desk.widget("keepAwake", desk.width - SMALL[0] - 24, MENUBAR_HEIGHT + 5 + pop_h + 28)
    drop_shadow(canvas, frame, 60, blur=40, offset=16, opacity=150)
    canvas.paste(desk.image, frame[:2], rounded_mask(desk.image.size, 60))
    edge = Image.new("RGBA", desk.image.size, (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle((0, 0, edge.width - 1, edge.height - 1), 60, outline=(255, 255, 255, 70),
                                           width=3)
    canvas.alpha_composite(edge, frame[:2])
    return canvas


def page_diagnostic(assets: Assets) -> Image.Image:
    """04: the Diagnostic. A light page: the title on top, the popup (card, question and answer by Apple's model),
    both widgets and what the module promises."""
    canvas = backdrop((214, 226, 250), (238, 226, 248), [
        (0.15, 0.80, 0.35, (180, 200, 255), 160), (0.85, 0.20, 0.30, (255, 214, 190), 150),
        (0.70, 0.90, 0.30, (210, 190, 255), 140),
    ])
    left = 150
    ink = (22, 26, 48, 255)
    write(canvas, (left, 120), TITLES[3], fit_lines(TITLES[3], "Heavy", W - 2 * left, 124, 1), ink)
    k = 2.7
    tint, border = (255, 255, 255, 215), (255, 255, 255, 200)
    _, pop_h = card(canvas, assets.get("popup-diagnostic"), (left, 330), k, 14, (246, 246, 248, 235), (0, 0, 0, 30))
    right = left + round(340 * k) + 110
    med_w, med_h = card(canvas, assets.get("widget-diagnostic-medium"), (right, 380), k, 22, tint, border)
    small_y = 380 + med_h + 80
    small_w, _ = card(canvas, assets.get("widget-diagnostic-small"), (right, small_y), k, 22, tint, border)
    tx = right + small_w + 90
    face_head, face = font("Heavy", 60), font("Medium", 46)
    y = small_y + 10
    for head, line in [("Sur l’appareil", "Rien ne quitte votre Mac."),
                       ("Un verdict clair", "Un titre, deux phrases, le bon bouton."),
                       ("Vos questions", "Posez-les, il répond avec vos chiffres.")]:
        y = write(canvas, (tx, y), head, face_head, (88, 70, 200, 255))
        y = write(canvas, (tx, y + 6), line, face, (60, 64, 86, 255), width=W - tx - 120, leading=1.18) + 34
    return canvas


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", required=True)
    parser.add_argument("--assets", required=True, help="folder of a `Renderer --store` run")
    args = parser.parse_args()
    for title in TITLES:
        check_text(title)
    assets = Assets(Path(args.assets))
    out = Path(args.root) / "interne" / "appstore-screenshots-1.1" / "fr"
    for index, page in enumerate([page_promise, page_overview, page_keep_awake, page_diagnostic], start=1):
        image = page(assets)
        if image.size != APPSTORE_SIZE:
            fail(f"{index:02d}: {image.size} instead of {APPSTORE_SIZE}")
        path = out / f"{index:02d}.png"
        size = save_png(image, path)
        print(f"  {path.relative_to(Path(args.root))} {image.width}x{image.height} {size // 1024} KB")


if __name__ == "__main__":
    main()
