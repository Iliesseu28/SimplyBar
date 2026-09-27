#!/usr/bin/env python3
"""Records the voice-over of the promo video, one WAV per line of src/narration.json, with Gemini text-to-speech on
Vertex AI, then writes src/voice.json (duration of each line, in seconds) for the timeline.

  VERTEX_PROJECT=<project> python3 scripts/voice.py                     # records the lines that have no WAV yet
  VERTEX_PROJECT=<project> python3 scripts/voice.py --force intro drag  # records these lines again
  python3 scripts/voice.py --durations                                  # only measures the WAVs

Needs gcloud logged in (the access token comes from `gcloud auth print-access-token`) and ffmpeg. The recordings are
kept in git (public/voice): a new take never sounds the same, so the video renders again without this script.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NARRATION = ROOT / "src" / "narration.json"
VOICE_DIR = ROOT / "public" / "voice"
DURATIONS = ROOT / "src" / "voice.json"


def token() -> str:
    result = subprocess.run(["gcloud", "auth", "print-access-token"], capture_output=True, text=True)
    if result.returncode != 0 or not result.stdout.strip():
        sys.exit("voice.py: gcloud gave no access token (run gcloud auth login)")
    return result.stdout.strip()


def synthesize(project: str, access: str, model: str, voice: str, prompt: str) -> bytes:
    """Raw PCM, 16 bits, mono, 24 kHz."""
    url = (f"https://aiplatform.googleapis.com/v1/projects/{project}/locations/global/publishers/google/models/"
           f"{model}:generateContent")
    body = {
        "contents": [{"role": "user", "parts": [{"text": prompt}]}],
        "generationConfig": {
            "responseModalities": ["AUDIO"],
            "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": voice}}},
        },
    }
    request = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST", headers={
        "Authorization": f"Bearer {access}", "Content-Type": "application/json"})
    for attempt in range(1, 7):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                data = json.load(response)
            break
        except urllib.error.HTTPError as error:
            # The text-to-speech models allow a few requests per minute: wait and try again.
            if error.code == 429 and attempt < 6:
                print(f"  quota reached, waiting {15 * attempt} s", flush=True)
                time.sleep(15 * attempt)
                continue
            sys.exit(f"voice.py: Vertex answered {error.code}: {error.read()[:300].decode(errors='replace')}")
    part = data["candidates"][0]["content"]["parts"][0]["inlineData"]
    if "rate=24000" not in part.get("mimeType", ""):
        sys.exit(f"voice.py: unexpected audio format {part.get('mimeType')}")
    return base64.b64decode(part["data"])


def to_wav(pcm: bytes, path: Path) -> None:
    """PCM to a 48 kHz mono WAV, silence trimmed at both ends (a take often starts or ends with a breath of it)."""
    trim = "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.05"
    command = ["ffmpeg", "-loglevel", "error", "-y", "-f", "s16le", "-ar", "24000", "-ac", "1", "-i", "pipe:0",
               "-af", f"{trim},areverse,{trim},areverse", "-ar", "48000", "-ac", "1", str(path)]
    subprocess.run(command, input=pcm, check=True)


def duration(path: Path) -> float:
    result = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                            capture_output=True, text=True, check=True)
    return round(float(result.stdout.strip()), 3)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--force", nargs="*", default=None, help="record these line ids again (all when empty)")
    parser.add_argument("--durations", action="store_true", help="only measure the recordings")
    args = parser.parse_args()
    narration = json.loads(NARRATION.read_text(encoding="utf-8"))
    VOICE_DIR.mkdir(parents=True, exist_ok=True)
    forced = set(args.force or [])
    access = None
    for line in [] if args.durations else narration["lines"]:
        path = VOICE_DIR / f"{line['id']}.wav"
        again = args.force is not None and (not forced or line["id"] in forced)
        if path.exists() and not again:
            continue
        project = os.environ.get("VERTEX_PROJECT")
        if not project:
            sys.exit("voice.py: set VERTEX_PROJECT (the Google Cloud project that runs Vertex AI)")
        access = access or token()
        print(f"recording {line['id']}...", flush=True)
        pcm = synthesize(project, access, narration["model"], narration["voice"], f"{narration['style']} {line['text']}")
        to_wav(pcm, path)
    durations = {line["id"]: duration(VOICE_DIR / f"{line['id']}.wav") for line in narration["lines"]}
    DURATIONS.write_text(json.dumps(durations, indent=2) + "\n", encoding="utf-8")
    for key, value in durations.items():
        print(f"  {key}: {value:.2f} s")
    print(f"  total: {sum(durations.values()):.2f} s")


if __name__ == "__main__":
    main()
