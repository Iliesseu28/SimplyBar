#!/usr/bin/env python3
"""Writes the Mac App Store screenshots of SimplyBar 1.1, in every language of the listing, from the renderer's images.

Called by `make.sh --store` (read it first): the renderer, launched with --store once per language, draws the real
views of the app (menu bar items, popups, widgets, the Diagnostic written by Apple's model where it takes the
language) into <assets root>/<language>/, then this script lays out five pages of 2880 x 1800 into
interne/appstore-screenshots-1.1/<listing code>/. One series: a soft black with a faint blue halo, one blue accent, a
title in two beats (white, then blue), at most three short grey lines, the app's real views floating at different
depths. The texts are in store_titles.json. Right-to-left languages get the whole composition mirrored. Each page has
its own composition:

  01  the menu bar as a band on top, the title on the left, widgets on the right
  02  the title on top, the menu bar and the CPU popup on the right, the 1.0 widgets on the left
  03  Keep Awake: the cup, the popup and the widget on the left, the title on the right
  04  the Diagnostic: widgets top left, the popup on the right, the title at the bottom left
  05  Health and alerts: the title centred on top, the heat alert, the popup and the widget under it

Check the texts alone (sizes, missing glyphs, typography): python3 compose_store.py --check [languages]
Run alone on an earlier run: python3 compose_store.py --root <repo> --assets-root <folder> [languages] [--only 02 03]
"""

from __future__ import annotations

import argparse
import functools
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compose import (APPSTORE_SIZE, FALLBACK_FONT, FONTS, FORBIDDEN_DASHES, MENUBAR_HEIGHT,  # noqa: E402
                     NO_SPACE_SCRIPTS, RTL_LANGUAGES, has_glyph, STORE_CODES, Assets, TitleType, lerp, load_font, rounded_mask,
                     save_png, scaled)

W, H = APPSTORE_SIZE
SF = "/System/Library/Fonts/SFNS.ttf"
NBSP = " "

# The 1.1 menu bar, left to right: the first item declared in SimplyBarApp.swift ends up rightmost. Health is hidden
# by default and stays out.
BAR_ORDER = ["keepAwake", "diagnostic", "bluetooth", "gpu", "disk", "network", "memory", "cpu"]

HERE = Path(__file__).resolve().parent
TEXTS = json.loads((HERE / "store_titles.json").read_text(encoding="utf-8"))
LANGUAGES = [code for code in TEXTS if not code.startswith("_")]
# Per page: title size, width it may take, grey line size. A title too wide shrinks, never under TITLE_MIN of its
# size (a grey line: GREY_MIN), else the check fails and the translation must be shortened in store_titles.json.
LAYOUT = {"01": (250, 1330, 84), "02": (200, 2500, 0), "03": (190, 1050, 72), "04": (190, 1620, 76),
          "05": (190, 2500, 72)}
TITLE_MIN, GREY_MIN = 0.8, 0.85
FRENCH_END_05 = 0  # set below, once headline() exists

# The language of the page being drawn: set by `use_language` before each page.
LANG = "fr"
RTL = False


def use_language(language: str) -> None:
    global LANG, RTL
    LANG, RTL = language, language.split("-")[0] in RTL_LANGUAGES


def fail(message: str) -> None:
    sys.exit(f"compose_store.py: {message}")


def check_text(text: str, language: str | None = None) -> None:
    """No long dash in any language; in French of France, the non-breaking space before : ? ! % (in Canadian
    French, before : and % only)."""
    language = language or LANG
    for char, name in FORBIDDEN_DASHES.items():
        if char in text:
            fail(f"{language}: {name} in {text!r}")
    marks = {"fr": ":?!%", "fr-CA": ":%"}.get(language, "")
    for index, char in enumerate(text):
        if char in marks and index > 0 and text[index - 1] != NBSP:
            fail(f"{language}: no non-breaking space before {char!r} in {text!r}")


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


class Lettering(TitleType):
    """Lettering of one language at one size and weight: the script's own font first (SF Pro for Latin, Greek,
    Cyrillic and Vietnamese, in `weight`), then SF Pro for what it lacks ("Mac" in a Hindi title), then Arial Unicode.
    Runs, shaping and right-to-left order come from compose.TitleType."""

    def __init__(self, language: str, size: int, weight: str):
        base = language.split("-")[0]
        self.language, self.rtl, self.size = base, base in RTL_LANGUAGES, size
        # Urdu in Nastaliq is too tall for a two-line title: Naskh (SF Arabic) is the usual display face.
        script = FONTS["ar"] if base == "ur" else FONTS.get(language) or FONTS.get(base)
        self.specs = ([script] if script else []) + [(SF, weight), FALLBACK_FONT]
        self.fonts = [load_font(spec, size) for spec in self.specs]
        metrics = [font.getmetrics() for font in self.fonts[:2]]
        self.ascent = max(ascent for ascent, _ in metrics)
        # SF Pro sets lines like the French pages; other scripts need their own ascent and descent.
        # (Mukta Mahee, for Punjabi, declares 1.7 times its size: capped, its marks still clear the next line.)
        self.line_height = (round(size * 1.08) if script is None else
                            min(round(max(a + d for a, d in metrics) * 1.02), round(size * 1.45)))


    def runs(self, text: str) -> list[tuple[str, int]]:
        """As compose.TitleType, except that on a right-to-left line the punctuation ending it belongs to the
        right-to-left text, as the bidi algorithm wants: "جهاز Mac." ends with its period on the far left, not
        glued to "Mac"."""
        core = text.rstrip(".،؟!:۔?")
        tail = text[len(core):]
        if not self.rtl or not tail or not core:
            return super().runs(text)
        runs = super().runs(core)
        if all(has_glyph(self.specs[0], char) for char in tail):
            if runs[-1][1] == 0:
                runs[-1] = (runs[-1][0] + tail, 0)
            else:
                runs.append((tail, 0))
        else:  # SF Hebrew has no question mark: drawn by the next font, still at the end of the line
            runs.append((tail, next(i for i, spec in enumerate(self.specs) if all(has_glyph(spec, c) for c in tail))))
        return runs


@functools.lru_cache(maxsize=None)
def lettering(language: str, size: int, weight: str) -> Lettering:
    return Lettering(language, size, weight)


def fit(texts, size: int, width: float, weight: str, minimum: float, language: str | None = None) -> Lettering:
    """The largest lettering, from `size` down to `minimum` of it, that writes each text on one line in `width`."""
    language = language or LANG
    for text in texts:
        check_text(text, language)
        missing = lettering(language, 64, weight).missing(text)
        if missing:
            fail(f"{language}: no font draws {''.join(missing)} in {text!r}")
    for candidate in range(size, round(size * minimum) - 1, -2):
        face = lettering(language, candidate, weight)
        if all(face.width(text) <= width for text in texts):
            return face
    widest = max(texts, key=lambda text: lettering(language, size, weight).width(text))
    fail(f"{language}: too long even at {round(minimum * 100)} % of the size, shorten it: {widest!r}")


def say(canvas: Image.Image | None, x: float, y: float, text: str, face: Lettering, fill, align: str = "start") -> float:
    """Writes one line with its top at `y`: from `x` (mirrored on a right-to-left page), or centred on `x`. Returns
    the y of the next line; with no canvas, only that."""
    if canvas is None:  # measuring only
        return y + face.line_height
    width = face.width(text)
    if align == "center":
        left = x - width / 2
    elif RTL:
        left = W - x - width
    else:
        left = x
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    face.draw(ImageDraw.Draw(layer), left + width / 2, y + face.ascent, text, fill)
    canvas.alpha_composite(layer)
    return y + face.line_height


def place(canvas: Image.Image, image: Image.Image, xy) -> None:
    """Pastes `image` with its top left corner at `xy`, mirrored on a right-to-left page."""
    x, y = xy
    canvas.alpha_composite(image, (round(W - x - image.width) if RTL else round(x), round(y)))


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
        cx = 1 - cx if RTL else cx
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


def catalog(root: Path, key: str) -> str:
    """The app's text for `key` in the page's language, from its String Catalog (English: the key itself)."""
    strings = json.loads((root / "Shared" / "Localizable.xcstrings").read_text())["strings"]
    if key not in strings:
        fail(f"{key!r} is not in the String Catalog")
    unit = strings[key].get("localizations", {}).get(LANG, {}).get("stringUnit", {})
    if not unit.get("value") and not LANG.startswith("en"):
        fail(f"{LANG}: no text for {key!r} in the String Catalog")
    return unit.get("value") or key


def wrap_to(face: Lettering, text: str, width: float) -> list[str]:
    """Greedy wrap, on spaces, or between characters for Chinese and Japanese."""
    pieces = list(text) if LANG in NO_SPACE_SCRIPTS else text.split(" ")
    glue = "" if LANG in NO_SPACE_SCRIPTS else " "
    lines, line = [], ""
    for piece in pieces:
        candidate = f"{line}{glue}{piece}" if line else piece
        if line and face.width(candidate) > width:
            lines.append(line)
            line = piece
        else:
            line = candidate
    return lines + ([line] if line else [])


def notification(root: Path, title: str, body: str, when: str, k: float) -> Image.Image:
    """A macOS notification banner of the app, drawn after the system one in light mode: the app icon on the left
    (right on a right-to-left page), the title in bold with the time across from it, the body under it, on a light
    rounded material."""
    width, pad, gap, side = round(344 * k), round(14 * k), round(10 * k), round(36 * k)
    bold, regular = lettering(LANG, round(13 * k), "Bold"), lettering(LANG, round(13 * k), "Regular")
    small = lettering(LANG, round(12 * k), "Regular")
    for text in (title, body, when):
        check_text(text)
    text_x = pad + side + gap
    lines = wrap_to(regular, body, width - text_x - pad)
    step = round(regular.line_height * 1.0)
    height = pad + bold.line_height + len(lines) * step + pad
    card = Image.new("RGBA", (width, height), (238, 239, 243, 255))
    icon = Image.open(root / "SimplyBar" / "Assets.xcassets" / "AppIcon.appiconset" / "icon_512x512.png")
    icon = icon.convert("RGBA").resize((side, side), Image.LANCZOS)
    card.alpha_composite(icon, (width - pad - side if RTL else pad, (height - side) // 2))
    layer = Image.new("RGBA", card.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    def line(text: str, face: Lettering, x: float, y: float, fill, at_end: bool = False) -> None:
        w = face.width(text)
        left = (x - w if not RTL else width - x) if at_end else (width - x - w if RTL else x)
        face.draw(draw, left + w / 2, y + face.ascent, text, fill)

    line(title, bold, text_x, pad, (20, 20, 22, 255))
    line(when, small, width - pad, pad + round(1 * k), (120, 120, 128, 255), at_end=True)
    for index, text in enumerate(lines):
        line(text, regular, text_x, pad + bold.line_height + index * step, (40, 40, 44, 255))
    card.alpha_composite(layer)
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
    and offset grow with `depth` (the higher it floats, the larger and softer the shadow). Mirrored on a
    right-to-left page."""
    if RTL:
        xy, angle = (W - xy[0] - card.width, xy[1]), -angle
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
    order = BAR_ORDER[::-1] if RTL else BAR_ORDER  # macOS mirrors its menu bar for a right-to-left language
    widths = [assets.points(names.get(module, f"menubar-{module}"))[0] + 14 for module in order]
    pad = 12
    width, height = round((sum(widths) + 2 * pad) * k), round(MENUBAR_HEIGHT * 1.5 * k)
    pill = Image.new("RGBA", (width, height), (250, 250, 252, 255))
    x = pad
    for module, slot in zip(order, widths):
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


def page_promise(assets: Assets, text: dict, ai: bool) -> Image.Image:
    """01, dark: the app's menu bar enlarged as a floating band, one strong headline, three short titles, the
    widgets floating on the right at different depths. No paragraph."""
    canvas = backdrop((13, 14, 18), (18, 20, 28), [
        (0.78, 0.62, 0.32, (20, 70, 170), 110), (0.95, 0.15, 0.20, (30, 60, 120), 70),
    ])
    pill = menubar_pill(assets, 4.4)
    float_on(canvas, pill, ((W - pill.width) / 2, 120), depth=40, tint=(0, 0, 0), opacity=160)

    size, width, grey_size = LAYOUT["01"]
    left = 170
    big = fit(text["p1"], size, width, "Heavy", TITLE_MIN)
    greys = [text["l1"][0], text["l1"][1] if ai else text["l1_noai"], text["l1"][2]]
    face = fit(greys, grey_size, width, "Bold", GREY_MIN)
    step = face.line_height + round(face.size * 0.6)
    # A tall script's lines would run off the bottom: the whole block moves up as much.
    up = max(0, max(1110, 420 + 2 * big.line_height + 150) + 3 * step - round(face.size * 0.6) - 1750)
    y = say(canvas, left, 420 - up, text["p1"][0], big, WHITE + (255,))
    y = say(canvas, left, y, text["p1"][1], big, ACCENT_ON_DARK + (255,))
    y = max(1110 - up, y + 150)
    for line in greys:
        y = say(canvas, left, y, line, face, GREY + (255,)) + round(face.size * 0.6)

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


def headline(canvas: Image.Image | None, x: float, y: float, pair, page: str, greys=(), align: str = "start") -> float:
    """The title in two beats, white then blue, each on one line, then up to three short grey lines. Returns where
    the block ends; with no canvas, only that."""
    size, width, grey_size = LAYOUT[page]
    face = fit(pair, size, width, "Heavy", TITLE_MIN)
    y = say(canvas, x, y, pair[0], face, WHITE + (255,), align)
    y = say(canvas, x, y, pair[1], face, ACCENT_ON_DARK + (255,), align)
    if greys:
        small = fit(greys, grey_size, width, "Bold", GREY_MIN)
        y += round(small.size * 0.95)
        for line in greys:
            y = say(canvas, x, y, line, small, GREY + (255,), align) + round(small.size * 0.6)
    return y


def page_overview(assets: Assets, text: dict, ai: bool) -> Image.Image:
    """02: the title on top; under it the app's menu bar enlarged, the CPU popup hanging from its item on the
    right, the widgets of version 1.0 floating on the left at different depths."""
    canvas = dark([(0.45, 0.80, 0.42, (20, 70, 170), 105), (0.90, 0.75, 0.25, (30, 60, 130), 70)])
    end = headline(canvas, 170, 100, text["p2"], "02")

    pill = menubar_pill(assets, 4.0, lit="cpu", cup_on=False)
    pill_x, pill_y = W - 120 - pill.width, max(640, round(end) + 10)  # lower under a tall script's title
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


def page_keep_awake(assets: Assets, text: dict, ai: bool) -> Image.Image:
    """03: the views on the left (the cup of the menu bar very large, lit in the accent, the popup, the widget), the
    title on the right."""
    canvas = dark([(0.25, 0.50, 0.40, (20, 70, 170), 110), (0.05, 0.10, 0.25, (30, 60, 130), 60)])
    cup = assets.get("menubar-keepAwake-on-large")  # drawn at 36 pixels per point, shown as is
    place(canvas, glowing(cup), (470 - cup.width // 2 - GLOW_PAD, 430 - cup.height // 2 - GLOW_PAD))

    k = 2.6
    float_on(canvas, tile(assets.get("popup-keepAwake-display"), k, 14, (246, 246, 248)), (700, 720), angle=3,
             depth=70, tint=(0, 0, 0))
    float_on(canvas, tile(assets.get("widget-keepAwake"), k, 22, (252, 252, 253)), (1220, 1290), angle=-6,
             depth=90, tint=(0, 0, 0))

    headline(canvas, 1700, 560, text["p3"], "03", greys=text["l3"])
    return canvas


def page_diagnostic(assets: Assets, text: dict, ai: bool) -> Image.Image:
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
    pair = text["p4"] if ai else text["p4_noai"]
    # A tall script's title and line would run off the bottom: the block moves up as much.
    top = 980 - max(0, round(headline(None, 170, 980, pair, "04", greys=(text["l4"],))) - 1740)
    headline(canvas, 170, top, pair, "04", greys=(text["l4"],))
    return canvas


def page_health(assets: Assets, text: dict, ai: bool, root: Path) -> Image.Image:
    """05: the title centred on top, the heat alert of the app as macOS shows it under it, then the Health popup
    and widget floating on each side."""
    canvas = dark([(0.50, 0.45, 0.45, (20, 70, 170), 110), (0.15, 0.85, 0.30, (30, 60, 130), 60),
                   (0.85, 0.85, 0.30, (30, 60, 130), 60)])
    end = headline(canvas, W / 2, 110, text["p5"], "05", greys=(text["l5"],), align="center")
    # Scripts with taller lines (Devanagari, Thai...) end lower than the French page: the views move down as much.
    low = max(0, end - FRENCH_END_05)

    float_on(canvas, tile(assets.get("popup-health"), 2.2, 14, (246, 246, 248)), (300, 800 + low), angle=-4,
             depth=80, tint=(0, 0, 0))
    float_on(canvas, tile(assets.get("widget-health-medium"), 2.6, 22, (252, 252, 253)), (1580, 1160 + low),
             angle=4, depth=70, tint=(0, 0, 0))
    banner = notification(root, catalog(root, "Your Mac is hot"),
                          catalog(root, "macOS slows the Mac down to cool it. Quit heavy apps and keep the vents "
                                        "clear."), text["now"], 2.9)
    float_on(canvas, banner, (1310, 760 + low), depth=60, tint=(0, 0, 0), opacity=150)
    return canvas


def french_end_05() -> int:
    """Where the title and grey line of page 05 end in French, the page the others follow."""
    use_language("fr")
    end = headline(Image.new("RGBA", (W, 400)), W / 2, 110, TEXTS["fr"]["p5"], "05", greys=(TEXTS["fr"]["l5"],),
                   align="center")
    return round(end)


def check(languages: list[str]) -> None:
    """Every text of these languages fits its page and every character has a font, without any rendering. Prints
    what had to shrink, and stops after listing every language that does not fit."""
    problems = []
    for language in languages:
        try:
            check_language(language)
        except SystemExit as error:
            problems.append(str(error))
    if problems:
        sys.exit("\n".join(problems))


def check_language(language: str) -> None:
    if True:
        use_language(language)
        text = TEXTS[language]
        for page, keys in [("01", ["p1"]), ("02", ["p2"]), ("03", ["p3"]), ("04", ["p4", "p4_noai"]), ("05", ["p5"])]:
            size, width, grey_size = LAYOUT[page]
            faces = [fit(text[key], size, width, "Heavy", TITLE_MIN) for key in keys]
            greys = {"01": text["l1"] + [text["l1_noai"]], "03": text["l3"], "04": [text["l4"]], "05": [text["l5"]]}
            grey = fit(greys[page], grey_size, width, "Bold", GREY_MIN) if page in greys else None
            if min(face.size for face in faces) < size or (grey and grey.size < grey_size):
                print(f"  {language} {page}: title {min(face.size for face in faces)}/{size}"
                      + (f", grey {grey.size}/{grey_size}" if grey else ""))
        check_text(text["now"], language)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("languages", nargs="*", help="app codes (fr, de, zh-Hans); all of store_titles.json if none")
    parser.add_argument("--root")
    parser.add_argument("--assets-root", help="folder of a `make.sh --store` run, one subfolder per language")
    parser.add_argument("--only", nargs="+", choices=["01", "02", "03", "04", "05"], help="write only these pages")
    parser.add_argument("--check", action="store_true", help="only check the texts: fit, glyphs, typography")
    args = parser.parse_args()
    languages = args.languages or LANGUAGES
    unknown = [language for language in languages if language not in TEXTS]
    if unknown:
        fail(f"no texts in store_titles.json for {' '.join(unknown)}")
    global FRENCH_END_05
    FRENCH_END_05 = french_end_05()
    check(languages)
    if args.check:
        return
    if not args.root or not args.assets_root:
        fail("--root and --assets-root are required (run make.sh --store)")
    root = Path(args.root)
    for language in languages:
        use_language(language)
        folder = Path(args.assets_root) / language
        assets = Assets(folder)
        ai = "status: available" in (folder / "render.log").read_text(errors="replace")
        text = TEXTS[language]
        out = root / "interne" / "appstore-screenshots-1.1" / STORE_CODES.get(language, language)
        pages = [("01", page_promise), ("02", page_overview), ("03", page_keep_awake), ("04", page_diagnostic),
                 ("05", lambda assets, text, ai: page_health(assets, text, ai, root))]
        for name, page in pages:
            if args.only and name not in args.only:
                continue
            image = page(assets, text, ai)
            if image.size != APPSTORE_SIZE:
                fail(f"{language} {name}: {image.size} instead of {APPSTORE_SIZE}")
            size = save_png(image, out / f"{name}.png")
        print(f"  {out.relative_to(root)} {'Apple model' if ai else 'rules only'}, last page {size // 1024} KB",
              flush=True)


if __name__ == "__main__":
    main()
