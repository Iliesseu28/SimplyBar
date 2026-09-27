#!/usr/bin/env python3
"""Draws what the promo video needs besides the app's own views, into public/gen (ignored by git):

  wallpaper.jpg  the desktop picture of the screenshots (tools/screenshots/compose.py), at 2 pixels per point
  icon.png       the app icon
  click.wav      a short, soft mouse click
  drop.wav       a softer one, when a widget lands on the desktop
  pad.wav        a very quiet synthesized chord under the voice

Everything is generated here: no sample, no music from elsewhere. Needs Python 3 with Pillow.
"""

from __future__ import annotations

import math
import random
import shutil
import struct
import sys
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO = ROOT.parent.parent
OUT = ROOT / "public" / "gen"
RATE = 48_000
DESKTOP = (1440, 810)  # points, as in src/layout.ts

sys.dont_write_bytecode = True  # no __pycache__ left in tools/screenshots
sys.path.insert(0, str(REPO / "tools" / "screenshots"))
import compose  # noqa: E402  (the screenshots' own drawing code)


def write_wav(path: Path, left: list[float], right: list[float]) -> None:
    frames = bytearray()
    for a, b in zip(left, right):
        frames += struct.pack("<hh", round(max(-1, min(1, a)) * 32767), round(max(-1, min(1, b)) * 32767))
    with wave.open(str(path), "wb") as file:
        file.setnchannels(2)
        file.setsampwidth(2)
        file.setframerate(RATE)
        file.writeframes(bytes(frames))


def click(path: Path, gain: float, pitch: float) -> None:
    """A trackpad-like tick: a few milliseconds of filtered noise over a damped high tone."""
    rng = random.Random(7)
    count = int(RATE * 0.045)
    samples, low = [], 0.0
    for index in range(count):
        t = index / RATE
        noise = rng.uniform(-1, 1)
        low += 0.35 * (noise - low)  # one-pole low-pass: takes the hiss off the noise
        body = math.sin(2 * math.pi * pitch * t) * math.exp(-t * 260)
        snap = low * math.exp(-t * 900)
        samples.append(gain * (0.55 * body + 0.8 * snap))
    write_wav(path, samples, samples)


def pad(path: Path, seconds: float) -> None:
    """A soft major-ninth chord, slowly breathing, 20 dB under the voice before the final loudness pass."""
    notes = [130.81, 196.00, 329.63, 493.88, 587.33]  # C3 G3 E4 B4 D5
    count = int(RATE * seconds)
    left, right = [0.0] * count, [0.0] * count
    for number, frequency in enumerate(notes):
        pan = 0.5 + 0.35 * math.sin(number * 2.1)
        detune = 1.0 + 0.0015 * (number % 2 * 2 - 1)
        weight = 0.22 / (1 + number * 0.35)
        for index in range(count):
            t = index / RATE
            swell = 0.75 + 0.25 * math.sin(2 * math.pi * t / (7 + number) + number)
            value = weight * swell * (math.sin(2 * math.pi * frequency * t)
                                      + 0.5 * math.sin(2 * math.pi * frequency * detune * t))
            left[index] += value * (1 - pan)
            right[index] += value * pan
    fade_in, fade_out = int(RATE * 2.5), int(RATE * 3.0)
    for index in range(count):
        envelope = min(1.0, index / fade_in, (count - index) / fade_out)
        envelope = envelope * envelope * (3 - 2 * envelope)
        left[index] *= 0.16 * envelope
        right[index] *= 0.16 * envelope
    write_wav(path, left, right)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    compose.wallpaper(DESKTOP[0] * 2, DESKTOP[1] * 2).save(OUT / "wallpaper.jpg", quality=92)
    shutil.copyfile(REPO / "SimplyBar" / "Assets.xcassets" / "AppIcon.appiconset" / "icon_512x512@2x.png", OUT / "icon.png")
    click(OUT / "click.wav", gain=0.5, pitch=2400)
    click(OUT / "drop.wav", gain=0.35, pitch=900)
    pad(OUT / "pad.wav", seconds=29.0)
    print(f"prepared {', '.join(sorted(p.name for p in OUT.iterdir()))}")


if __name__ == "__main__":
    main()
