#!/usr/bin/env python3
"""Lays out the renderer's images on a drawn macOS desktop and writes the screenshots of SimplyBar.

Called by make.sh (read it first). For each language it runs the renderer, then writes:
  docs/images/{overview,menubar,popups,widgets}[-<lang>].png  for the languages of DOCS_LANGS (default: en fr)
  interne/appstore-screenshots/<lang>/01.png ... 05.png        2880 x 1800, title from titles.json

Everything is drawn here: the wallpaper (gradients and blurred shapes, no generated image), the menu bar, the
frosted panels behind the popups and the widgets, the titles. The app's own pixels come from the renderer.
Units: layouts are written in points of the virtual desktop, K is the number of pixels per point of an output.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
TITLES = HERE / "titles.json"
RENDER_SCALE = 4  # pixels per point of the renderer's images
APPSTORE_SIZE = (2880, 1800)
# Long dashes are refused in every text of the set (written as code points so this file holds none).
FORBIDDEN_DASHES = {chr(0x2014): "em dash", chr(0x2013): "en dash", chr(0x2015): "horizontal bar"}
DEMO_KEYS = ["gpu", "keyboard", "mouse", "headphones", "system", "photos", "backup", "archive"]
RTL_LANGUAGES = {"ar", "he", "fa", "ur"}
# Region for dates and numbers when titles.json gives none. Arabic: ar_AE keeps Latin digits and the Gregorian
# calendar, like the rest of the set.
LOCALES = {
    "en": "en_US", "en-GB": "en_GB", "en-AU": "en_AU", "en-CA": "en_CA", "fr": "fr_FR", "fr-CA": "fr_CA",
    "de": "de_DE", "es": "es_ES", "es-MX": "es_MX", "it": "it_IT", "pt-BR": "pt_BR", "pt-PT": "pt_PT", "nl": "nl_NL",
    "sv": "sv_SE", "da": "da_DK", "fi": "fi_FI", "nb": "nb_NO", "no": "nb_NO", "pl": "pl_PL", "cs": "cs_CZ",
    "sk": "sk_SK", "hu": "hu_HU", "ro": "ro_RO", "hr": "hr_HR", "sl": "sl_SI", "ca": "ca_ES", "tr": "tr_TR",
    "el": "el_GR", "ru": "ru_RU", "uk": "uk_UA", "ja": "ja_JP", "ko": "ko_KR", "zh-Hans": "zh_CN",
    "zh-Hant": "zh_TW", "zh-HK": "zh_HK", "ar": "ar_AE", "he": "he_IL", "th": "th_TH", "vi": "vi_VN",
    "id": "id_ID", "ms": "ms_MY", "hi": "hi_IN",
}
# Title fonts, by language: (file, named instance of a variable font or face index of a collection), best first.
# The first one that has every character of the language's five titles is used for all five (the SF Arabic and
# SF Hebrew files hold no Latin letters, so a title that says "Mac" falls back to Arial Bold).
FONTS = {
    "default": [("/System/Library/Fonts/SFNS.ttf", "Bold")],
    "ar": [("/System/Library/Fonts/SFArabic.ttf", "Bold"), ("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 0)],
    "he": [("/System/Library/Fonts/SFHebrew.ttf", "Bold"), ("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 0)],
    "ja": [("/System/Library/Fonts/\u30d2\u30e9\u30ae\u30ce\u89d2\u30b4\u30b7\u30c3\u30af W7.ttc", 0)],
    "zh-Hans": [("/System/Library/Fonts/Hiragino Sans GB.ttc", 2)],
    "zh-Hant": [("/System/Library/Fonts/STHeiti Medium.ttc", 0)],
    "zh-HK": [("/System/Library/Fonts/STHeiti Medium.ttc", 0)],
    "ko": [("/System/Library/Fonts/AppleSDGothicNeo.ttc", 6)],
    "th": [("/System/Library/Fonts/Supplemental/Thonburi.ttc", 1)],
    "hi": [("/System/Library/Fonts/Kohinoor.ttc", 3)],
}
FALLBACK_FONT = ("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", 0)
NO_SPACE_SCRIPTS = {"ja", "zh-Hans", "zh-Hant", "zh-HK"}

# The app's menu bar items, left to right: the first one declared in SimplyBarApp.swift ends up rightmost.
MENUBAR_ORDER = ["bluetooth", "gpu", "disk", "network", "memory", "cpu"]
MENUBAR_HEIGHT = 24
SMALL, MEDIUM, LARGE = (170, 170), (364, 170), (364, 382)
GRID_GAP_X, GRID_GAP_Y = 24, 42  # macOS lays widgets so that 2 x 2 small ones fill one large


def fail(message: str) -> None:
    sys.exit(f"compose.py: {message}")


# MARK: - Languages and texts

def load_titles() -> dict:
    with open(TITLES, encoding="utf-8") as handle:
        return json.load(handle)


def load_catalog(path: Path) -> dict:
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def catalog_languages(path: Path) -> list[str]:
    catalog = load_catalog(path)
    found = {catalog.get("sourceLanguage", "en")}
    for entry in catalog["strings"].values():
        found.update(entry.get("localizations", {}).keys())
    return sorted(found, key=lambda code: (code != "en", code))


def untranslated(path: Path, language: str) -> int:
    """Keys of the catalog with no translation in `language`: they would show in English on its screenshots."""
    catalog = load_catalog(path)
    if language == catalog.get("sourceLanguage", "en"):
        return 0
    missing = 0
    for entry in catalog["strings"].values():
        if entry.get("shouldTranslate") is False:
            continue
        local = entry.get("localizations", {}).get(language, {})
        unit = local.get("stringUnit") or {}
        if not unit.get("value") and "variations" not in local:
            missing += 1
    return missing


def check(languages: list[str], catalog: Path | None = None) -> dict:
    titles = load_titles()
    known = catalog_languages(catalog) if catalog and catalog.exists() else None
    problems = []
    for language in languages:
        entry = titles.get(language)
        if entry is None:
            problems.append(f"{language}: no entry in titles.json")
            continue
        if len(entry.get("titles", [])) != 5:
            problems.append(f"{language}: 5 titles expected")
        missing = [key for key in DEMO_KEYS if not entry.get("demo", {}).get(key)]
        if missing:
            problems.append(f"{language}: demo names missing: {', '.join(missing)}")
        for text in list(entry.get("titles", [])) + list(entry.get("demo", {}).values()):
            for dash, name in FORBIDDEN_DASHES.items():
                if dash in text:
                    problems.append(f"{language}: {name} in {text!r}")
        if known is not None and language not in known:
            problems.append(f"{language}: not in the string catalog, the app would show English")
    if problems:
        fail("titles.json is not ready:\n  " + "\n  ".join(problems))
    return titles


def locale_for(language: str, entry: dict) -> str:
    return entry.get("locale") or LOCALES.get(language) or language.replace("-", "_")


# MARK: - Drawing helpers

def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


_WALLPAPERS: dict = {}


def wallpaper(width: int, height: int) -> Image.Image:
    """A soft abstract desktop picture, drawn small, blurred, then enlarged (smooth, and light to compress)."""
    key = (width, height)
    if key in _WALLPAPERS:
        return _WALLPAPERS[key].copy()
    sw, sh = max(96, width // 10), max(60, height // 10)
    image = Image.new("RGB", (sw, sh))
    top, bottom = (36, 58, 150), (232, 146, 150)
    pixels = image.load()
    for y in range(sh):
        for x in range(sw):
            t = min(1.0, max(0.0, 0.8 * y / sh + 0.25 * x / sw))
            pixels[x, y] = lerp(top, bottom, t)
    layer = Image.new("RGBA", (sw, sh), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    blobs = [  # centre x, centre y, radius (share of the width), colour, opacity
        (0.12, 0.28, 0.42, (92, 72, 230), 200), (0.78, 0.18, 0.40, (46, 168, 246), 190),
        (0.52, 0.62, 0.34, (170, 96, 236), 150), (0.95, 0.80, 0.36, (255, 128, 150), 190),
        (0.22, 0.95, 0.40, (255, 170, 110), 170), (0.62, 0.05, 0.22, (120, 220, 255), 120),
    ]
    for cx, cy, r, colour, alpha in blobs:
        radius = r * sw
        draw.ellipse((cx * sw - radius, cy * sh - radius * 0.8, cx * sw + radius, cy * sh + radius * 0.8),
                     fill=colour + (alpha,))
    layer = layer.filter(ImageFilter.GaussianBlur(sw * 0.09))
    image = Image.alpha_composite(image.convert("RGBA"), layer).convert("RGB")
    image = image.filter(ImageFilter.GaussianBlur(1.2)).resize((width, height), Image.BICUBIC)
    _WALLPAPERS[key] = image
    return image.copy()


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", (size[0] * 2, size[1] * 2), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] * 2 - 1, size[1] * 2 - 1), radius * 2, fill=255)
    return mask.resize(size, Image.LANCZOS)


def drop_shadow(canvas: Image.Image, box, radius: int, blur: float, offset: int, opacity: int) -> None:
    x, y, w, h = box
    pad = int(blur * 3) + abs(offset)
    shadow = Image.new("L", (w + pad * 2, h + pad * 2), 0)
    ImageDraw.Draw(shadow).rounded_rectangle((pad, pad, pad + w, pad + h), radius, fill=opacity)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    tint = Image.new("RGBA", shadow.size, (8, 10, 30, 0))
    tint.putalpha(shadow)
    canvas.alpha_composite(tint, (x - pad, y - pad + offset))


def frosted(canvas: Image.Image, box, radius: int, tint, blur: float, border=(255, 255, 255, 90)) -> None:
    """Glass panel: what lies under it, blurred and tinted, cut with rounded corners."""
    x, y, w, h = box
    region = canvas.crop((x, y, x + w, y + h)).filter(ImageFilter.GaussianBlur(blur))
    region = Image.alpha_composite(region, Image.new("RGBA", (w, h), tint))
    canvas.paste(region, (x, y), rounded_mask((w, h), radius) if radius else None)
    if border:
        outline = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        ImageDraw.Draw(outline).rounded_rectangle((0, 0, w - 1, h - 1), radius, outline=border, width=max(1, w // 400))
        canvas.alpha_composite(outline, (x, y))


def scaled(image: Image.Image, k: float) -> Image.Image:
    factor = k / RENDER_SCALE
    if abs(factor - 1) < 1e-3:
        return image
    return image.resize((max(1, round(image.width * factor)), max(1, round(image.height * factor))), Image.LANCZOS)


def with_opacity(image: Image.Image, opacity: float) -> Image.Image:
    result = image.copy()
    result.putalpha(image.getchannel("A").point(lambda value: round(value * opacity)))
    return result


# MARK: - Desktop

class Assets:
    def __init__(self, folder: Path):
        self.folder = folder
        self.cache: dict = {}

    def get(self, name: str) -> Image.Image:
        if name not in self.cache:
            path = self.folder / f"{name}.png"
            if not path.exists():
                fail(f"missing renderer image {path}")
            self.cache[name] = Image.open(path).convert("RGBA")
        return self.cache[name]

    def points(self, name: str) -> tuple[float, float]:
        image = self.get(name)
        return image.width / RENDER_SCALE, image.height / RENDER_SCALE


class Desktop:
    """A virtual desktop of `width` x `height` points drawn at `k` pixels per point. Layouts are given left to
    right; for a right-to-left language every position is mirrored, as macOS mirrors its menu bar."""

    def __init__(self, assets: Assets, width: float, height: float, k: float, rtl: bool, menubar: bool = True):
        self.assets, self.width, self.height, self.k, self.rtl = assets, width, height, k, rtl
        self.image = wallpaper(round(width * k), round(height * k)).convert("RGBA")
        self.slots: dict[str, tuple[float, float]] = {}
        if menubar:
            self.draw_menubar()

    def px(self, value: float) -> int:
        return round(value * self.k)

    def box(self, x: float, y: float, w: float, h: float) -> tuple[int, int, int, int]:
        if self.rtl:
            x = self.width - x - w
        return self.px(x), self.px(y), self.px(w), self.px(h)

    def draw_menubar(self) -> None:
        frosted(self.image, (0, 0, self.image.width, self.px(MENUBAR_HEIGHT)), 0, (250, 250, 255, 105),
                9 * self.k, border=None)
        tray_w, tray_h = self.assets.points("menubar-system")
        x = self.width - 12 - tray_w
        self.paste_template("menubar-system", x, (MENUBAR_HEIGHT - tray_h) / 2)
        x -= 10
        for module in reversed(MENUBAR_ORDER):
            w, h = self.assets.points(f"menubar-{module}")
            slot = w + 14
            x -= slot
            self.slots[module] = (x, slot)
            self.paste_template(f"menubar-{module}", x + 7, (MENUBAR_HEIGHT - h) / 2)

    def paste_template(self, name: str, x: float, y: float) -> None:
        image = with_opacity(scaled(self.assets.get(name), self.k), 0.88)
        bx, by, _, _ = self.box(x, y, image.width / self.k, image.height / self.k)
        self.image.alpha_composite(image, (bx, by))

    def highlight(self, module: str) -> None:
        x, slot = self.slots[module]
        overlay = Image.new("RGBA", self.image.size, (0, 0, 0, 0))
        bx, by, bw, bh = self.box(x + 1, 2, slot - 2, MENUBAR_HEIGHT - 4)
        ImageDraw.Draw(overlay).rounded_rectangle((bx, by, bx + bw, by + bh), self.px(5), fill=(0, 0, 0, 34))
        self.image.alpha_composite(overlay)

    def popup(self, module: str, x: float | None = None, y: float = MENUBAR_HEIGHT + 5) -> tuple[float, float]:
        """A popup window; by default under its menu bar item, left edges aligned, kept on screen."""
        name = f"popup-{module}"
        w, h = self.assets.points(name)
        if x is None:
            x = min(max(8, self.slots[module][0]), self.width - w - 8)
            self.highlight(module)
        box = self.box(x, y, w, h)
        radius = self.px(14)
        drop_shadow(self.image, box, radius, blur=self.px(16), offset=self.px(8), opacity=110)
        frosted(self.image, box, radius, (246, 246, 248, 222), self.px(20), border=(0, 0, 0, 28))
        self.image.alpha_composite(scaled(self.assets.get(name), self.k), box[:2])
        return w, h

    def widget(self, name: str, x: float, y: float) -> None:
        w, h = self.assets.points(f"widget-{name}")
        box = self.box(x, y, w, h)
        radius = self.px(22)
        drop_shadow(self.image, box, radius, blur=self.px(10), offset=self.px(4), opacity=70)
        frosted(self.image, box, radius, (250, 250, 252, 196), self.px(18), border=(255, 255, 255, 120))
        self.image.alpha_composite(scaled(self.assets.get(f"widget-{name}"), self.k), box[:2])

    def widget_group(self, x: float, y: float) -> tuple[float, float]:
        """The five widgets: four small ones in a square, the large Storage widget beside them."""
        for index, name in enumerate(["cpu", "memory", "network", "disk"]):
            column, row = index % 2, index // 2
            self.widget(name, x + column * (SMALL[0] + GRID_GAP_X), y + row * (SMALL[1] + GRID_GAP_Y))
        self.widget("storage-large", x + LARGE[0] + GRID_GAP_X, y)
        return LARGE[0] * 2 + GRID_GAP_X, LARGE[1]


# MARK: - Scenes

def overview(assets: Assets, rtl: bool, width: float, height: float, k: float, popup: str,
             centred: bool = False) -> Image.Image:
    """The desktop: the five widgets on the left, a popup open under its menu bar item (always above the widgets)."""
    desk = Desktop(assets, width, height, k, rtl)
    y = MENUBAR_HEIGHT + (height - MENUBAR_HEIGHT - LARGE[1]) / 2 if centred else MENUBAR_HEIGHT + 40
    desk.widget_group(40, y)
    desk.popup(popup)
    return desk.image


def menubar_strip(assets: Assets, rtl: bool, k: float) -> Image.Image:
    probe = Desktop(assets, 2000, MENUBAR_HEIGHT, 1, False)
    used = probe.width - min(x for x, _ in probe.slots.values()) + 36
    return Desktop(assets, used, MENUBAR_HEIGHT, k, rtl).image


def popup_grid(assets: Assets, rtl: bool, k: float) -> Image.Image:
    """The six popups in three columns of two, paired so the columns end at about the same height."""
    columns = [["cpu", "bluetooth"], ["memory", "gpu"], ["network", "disk"]]
    gap = 32
    heights = [sum(assets.points(f"popup-{module}")[1] for module in column) + gap * (len(column) - 1)
               for column in columns]
    width = len(columns) * 300 + (len(columns) + 1) * gap
    desk = Desktop(assets, width, max(heights) + 2 * gap, k, rtl, menubar=False)
    for index, column in enumerate(columns):
        y = gap
        for module in column:
            _, h = desk.popup(module, x=gap + index * (300 + gap), y=y)
            y += h + gap
    return desk.image


def widget_board(assets: Assets, rtl: bool, k: float) -> Image.Image:
    margin = 40
    desk = Desktop(assets, LARGE[0] * 2 + GRID_GAP_X + margin * 2, LARGE[1] + margin * 2, k, rtl, menubar=False)
    desk.widget_group(margin, margin)
    return desk.image


class Screen:
    """The Mac App Store canvas: a dark backdrop, the title on top, a display showing the desktop below."""

    FRAME_X, FRAME_TOP, BEZEL = 100, 330, 18

    def __init__(self):
        width, height = APPSTORE_SIZE
        self.canvas = Image.new("RGBA", APPSTORE_SIZE)
        backdrop = Image.new("RGB", (96, 60))
        pixels = backdrop.load()
        for y in range(60):
            for x in range(96):
                pixels[x, y] = lerp((12, 16, 42), (34, 42, 96), min(1.0, 0.65 * y / 60 + 0.35 * x / 96))
        self.canvas.paste(backdrop.resize(APPSTORE_SIZE, Image.BICUBIC))
        self.screen_x = self.FRAME_X + self.BEZEL
        self.screen_y = self.FRAME_TOP + self.BEZEL
        self.screen_w = width - 2 * self.screen_x
        self.screen_h = height - self.screen_y
        frame = (self.FRAME_X, self.FRAME_TOP, width - 2 * self.FRAME_X, height - self.FRAME_TOP + 80)
        drop_shadow(self.canvas, frame, 46, blur=40, offset=10, opacity=150)
        body = Image.new("RGBA", (frame[2], frame[3]), (24, 26, 34, 255))
        self.canvas.paste(body, frame[:2], rounded_mask(body.size, 46))
        edge = Image.new("RGBA", (frame[2], frame[3]), (0, 0, 0, 0))
        ImageDraw.Draw(edge).rounded_rectangle((0, 0, frame[2] - 1, frame[3] - 1), 46, outline=(90, 96, 120, 255), width=3)
        self.canvas.alpha_composite(edge, frame[:2])

    def points(self, k: float) -> tuple[float, float]:
        return self.screen_w / k, self.screen_h / k

    def show(self, desktop: Image.Image) -> None:
        crop = desktop.crop((0, 0, self.screen_w, self.screen_h))
        self.canvas.paste(crop, (self.screen_x, self.screen_y), rounded_mask(crop.size, 30))


def appstore_shots(assets: Assets, rtl: bool) -> list[Image.Image]:
    shots = []

    # 1. The menu bar, enlarged, with the CPU popup open and four small widgets.
    popup_h = assets.points("popup-cpu")[1]
    screen = Screen()
    k = min(3.0, screen.screen_h / (MENUBAR_HEIGHT + 5 + popup_h + 18))
    width, height = screen.points(k)
    desk = Desktop(assets, width, height, k, rtl)
    for index, name in enumerate(["cpu", "memory", "network", "disk"]):
        column, row = index % 2, index // 2
        desk.widget(name, 36 + column * (SMALL[0] + GRID_GAP_X), MENUBAR_HEIGHT + 30 + row * (SMALL[1] + GRID_GAP_X))
    desk.popup("cpu")
    screen.show(desk.image)
    shots.append(screen.canvas)

    # 2. One detailed window per module: the six popups in four columns.
    screen = Screen()
    columns = [["cpu"], ["memory", "gpu"], ["network", "bluetooth"], ["disk"]]
    gap = 20
    tallest = max(sum(assets.points(f"popup-{module}")[1] for module in column) + gap * (len(column) - 1)
                  for column in columns)
    k = min(screen.screen_w / (len(columns) * 300 + (len(columns) + 1) * gap),
            screen.screen_h / (MENUBAR_HEIGHT + 2 * gap + tallest))
    width, height = screen.points(k)
    desk = Desktop(assets, width, height, k, rtl)
    gap_x = (width - len(columns) * 300) / (len(columns) + 1)
    for index, column in enumerate(columns):
        y = MENUBAR_HEIGHT + gap
        for module in column:
            _, h = desk.popup(module, x=gap_x + index * (300 + gap_x), y=y)
            y += h + gap
    screen.show(desk.image)
    shots.append(screen.canvas)

    # 3. The Storage widget in its three sizes, the large one listing every disk.
    screen = Screen()
    k = 2.8
    width, height = screen.points(k)
    desk = Desktop(assets, width, height, k, rtl)
    x0 = (width - (LARGE[0] * 2 + 40)) / 2
    y0 = MENUBAR_HEIGHT + (height - MENUBAR_HEIGHT - LARGE[1]) / 2
    desk.widget("storage-large", x0, y0)
    right = x0 + LARGE[0] + 40
    desk.widget("storage-medium", right, y0)
    desk.widget("storage-small", right, y0 + MEDIUM[1] + GRID_GAP_Y)
    desk.widget("disk", right + SMALL[0] + GRID_GAP_X, y0 + MEDIUM[1] + GRID_GAP_Y)
    screen.show(desk.image)
    shots.append(screen.canvas)

    # 4. The five desktop widgets.
    screen = Screen()
    k = 3.0
    width, height = screen.points(k)
    desk = Desktop(assets, width, height, k, rtl)
    group_w, group_h = LARGE[0] * 2 + GRID_GAP_X, LARGE[1]
    desk.widget_group((width - group_w) / 2, MENUBAR_HEIGHT + (height - MENUBAR_HEIGHT - group_h) / 2)
    screen.show(desk.image)
    shots.append(screen.canvas)

    # 5. The whole desktop: menu bar, the widgets, the memory popup.
    screen = Screen()
    k = 2.1
    width, height = screen.points(k)
    screen.show(overview(assets, rtl, width, height, k, "memory", centred=True))
    shots.append(screen.canvas)
    return shots


# MARK: - Titles

def load_font(spec: tuple, size: int) -> ImageFont.FreeTypeFont:
    path, style = spec
    if isinstance(style, int):
        return ImageFont.truetype(path, size, index=style, layout_engine=ImageFont.Layout.RAQM)
    font = ImageFont.truetype(path, size, layout_engine=ImageFont.Layout.RAQM)
    font.set_variation_by_name(style)
    return font


def title_font_spec(language: str, titles: list[str]) -> tuple:
    """The first font of the language's list that can write all its titles."""
    candidates = FONTS.get(language) or FONTS.get(language.split("-")[0]) or FONTS["default"]
    for spec in candidates + [FALLBACK_FONT]:
        if Path(spec[0]).exists():
            font = load_font(spec, 64)
            if not any(missing_glyphs(font, title) for title in titles):
                return spec
    font = load_font(candidates[0], 64)
    missing = sorted({char for title in titles for char in missing_glyphs(font, title)})
    fail(f"{language}: no title font has {''.join(missing)}, add one for this language in FONTS")


def missing_glyphs(font: ImageFont.FreeTypeFont, text: str) -> list[str]:
    """Characters the font lacks: they draw as its empty glyph, like a private-use code point."""
    def pixels(char: str) -> bytes:
        size = int(font.size * 2)
        image = Image.new("L", (size, size), 0)
        ImageDraw.Draw(image).text((size // 4, size // 4), char, font=font, fill=255)
        return image.tobytes()

    empty = pixels(chr(0xE000))
    return sorted({char for char in text if not char.isspace() and pixels(char) == empty})


def wrap_options(text: str, language: str) -> list[list[str]]:
    """The title on one line, then every way to cut it in two (at spaces, or between characters for CJK)."""
    options = [[text]]
    if language in NO_SPACE_SCRIPTS:
        closing = set("、。，！？：）」")
        cuts = [i for i in range(1, len(text)) if text[i] not in closing and text[i - 1] != " "]
        options += [[text[:i].rstrip(), text[i:].lstrip()] for i in cuts]
    else:
        words = text.split(" ")
        options += [[" ".join(words[:i]), " ".join(words[i:])] for i in range(1, len(words))]
    return options


def draw_title(canvas: Image.Image, text: str, language: str, font_spec: tuple, rtl: bool, band_height: int) -> None:
    max_width = canvas.width - 320
    features = {"direction": "rtl" if rtl else "ltr", "language": language.split("-")[0]}

    def line_height(font: ImageFont.FreeTypeFont) -> int:
        ascent, descent = font.getmetrics()
        return round((ascent + descent) * 1.08)

    def fitting(size: int, line_count: int):
        """The most even cut of the title into `line_count` lines at `size`, or None if none fits."""
        font = load_font(font_spec, size)
        if line_height(font) * line_count > band_height - 90:
            return None
        best = None
        for lines in wrap_options(text, language):
            if len(lines) != line_count:
                continue
            widths = [font.getlength(line, **features) for line in lines]
            if max(widths) <= max_width and (best is None or max(widths) - min(widths) < best[0]):
                best = (max(widths) - min(widths), lines)
        return (font, best[1]) if best else None

    # One large line; else two lines that leave a margin in the band; else one smaller line.
    passes = [(range(112, 83, -4), 1), (range(104, 55, -4), 2), (range(80, 47, -4), 1)]
    chosen = next((found for sizes, count in passes for size in sizes if (found := fitting(size, count))), None)
    if chosen is None:
        fail(f"title too long for the canvas: {text!r}")
    font, lines = chosen
    ascent, _ = font.getmetrics()
    step = line_height(font)
    top = (band_height - step * len(lines)) // 2 + 6
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    for index, line in enumerate(lines):
        draw.text((canvas.width / 2, top + index * step + ascent), line, font=font,
                  fill=(255, 255, 255, 255), anchor="ms", **features)
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow.putalpha(layer.getchannel("A").point(lambda value: round(value * 0.45)).filter(ImageFilter.GaussianBlur(10)))
    canvas.alpha_composite(shadow, (0, 6))
    canvas.alpha_composite(layer)


# MARK: - Output

def save_png(image: Image.Image, path: Path, limit: int | None = None) -> int:
    """Optimised PNG. Past `limit` bytes it is reduced to 256 well-chosen colours (the desktop is smooth)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    rgb = image.convert("RGB")
    rgb.save(path, "PNG", optimize=True)
    if limit and path.stat().st_size > limit:
        rgb.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.FLOYDSTEINBERG).save(
            path, "PNG", optimize=True)
    return path.stat().st_size


def render_language(args, language: str, entry: dict) -> None:
    folder = Path(args.work) / "renders" / language
    folder.mkdir(parents=True, exist_ok=True)
    demo_path = folder / "demo.json"
    demo_path.write_text(json.dumps(entry["demo"], ensure_ascii=False), encoding="utf-8")
    rtl = language.split("-")[0] in RTL_LANGUAGES
    command = [args.renderer, str(folder), str(demo_path), str(RENDER_SCALE), "rtl" if rtl else "ltr",
               "-AppleLanguages", f"({language})", "-AppleLocale", locale_for(language, entry)]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"renderer failed for {language}:\n{result.stderr[-2000:]}")


def compose_language(args, language: str, entry: dict, docs_languages: set[str]) -> list[str]:
    rtl = language.split("-")[0] in RTL_LANGUAGES
    assets = Assets(Path(args.work) / "renders" / language)
    root = Path(args.root)
    written = []
    if language in docs_languages:
        suffix = "" if language == "en" else f"-{language}"
        images = {
            "overview": overview(assets, rtl, 1200, 750, 1.6, "cpu", centred=True),
            "menubar": menubar_strip(assets, rtl, 3.0),
            "popups": popup_grid(assets, rtl, 1.6),
            "widgets": widget_board(assets, rtl, 2.0),
        }
        for name, image in images.items():
            path = root / "docs" / "images" / f"{name}{suffix}.png"
            size = save_png(image, path, limit=1_000_000)
            written.append(f"{path.relative_to(root)} {image.width}x{image.height} {size // 1024} KB")
    font_spec = title_font_spec(language, entry["titles"])
    for index, (shot, text) in enumerate(zip(appstore_shots(assets, rtl), entry["titles"]), start=1):
        draw_title(shot, text, language, font_spec, rtl, Screen.FRAME_TOP)
        if shot.size != APPSTORE_SIZE:
            fail(f"{language} {index:02d}: {shot.size} instead of {APPSTORE_SIZE}")
        path = root / "interne" / "appstore-screenshots" / language / f"{index:02d}.png"
        size = save_png(shot, path)
        written.append(f"{path.relative_to(root)} {shot.width}x{shot.height} {size // 1024} KB")
    return written


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("languages", nargs="*")
    parser.add_argument("--root")
    parser.add_argument("--work")
    parser.add_argument("--renderer")
    parser.add_argument("--check", action="store_true", help="only check titles.json for these languages")
    parser.add_argument("--list-catalog-languages", metavar="XCSTRINGS")
    args = parser.parse_args()

    if args.list_catalog_languages:
        print("\n".join(catalog_languages(Path(args.list_catalog_languages))))
        return
    languages = args.languages or ["en", "fr"]
    catalog = (Path(args.root) if args.root else HERE.parent.parent) / "Shared" / "Localizable.xcstrings"
    titles = check(languages, catalog)
    if args.check:
        return
    for option in ("root", "work", "renderer"):
        if not getattr(args, option):
            fail(f"--{option} is required (run make.sh)")

    docs_languages = set(os.environ.get("DOCS_LANGS", "en fr").split())
    for language in languages:
        missing = untranslated(catalog, language)
        if missing:
            print(f"warning: {language}: {missing} strings of the catalog have no translation and show in English")
        print(f"{language}: rendering...", flush=True)
        render_language(args, language, titles[language])
        for line in compose_language(args, language, titles[language], docs_languages):
            print(f"  {line}")


if __name__ == "__main__":
    main()
