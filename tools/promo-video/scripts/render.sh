#!/bin/zsh
# Renders SimplyBar's promo video and its poster, in one command:
#
#   zsh tools/promo-video/scripts/render.sh           # draws what is missing, renders, encodes
#   zsh tools/promo-video/scripts/render.sh --assets  # draws the app's views again first (after a change of the app)
#
# Output: docs/video/simplybar-promo.mp4 (1920 x 1080, 30 fps, H.264 High 4.0, AAC 256 kb/s 48 kHz stereo,
# loudness -16 LUFS) and docs/video/simplybar-promo-poster.jpg (the frame at POSTER seconds).
# Needs Node (npm), ffmpeg, Python 3 with Pillow, and Xcode for the app's views (tools/screenshots/make.sh).
# The voice is recorded once (scripts/voice.py) and kept in public/voice.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DOCS="$ROOT/docs/video"
POSTER=24.2  # seconds: every widget on the desktop, the menu bar items and a popup open, no subtitle
cd "$HERE"
mkdir -p out "$DOCS"

[[ -d node_modules ]] || npm ci
if [[ "${1:-}" == "--assets" || ! -f public/app/video-assets.json ]]; then
  zsh "$ROOT/tools/screenshots/make.sh" --video public/app
fi
python3 scripts/prepare.py

echo "Rendering (a few minutes)..."
npx remotion render SimplyBarPromo out/raw.mov --codec=prores --prores-profile=standard --log=error

# Loudness in two passes: measured first, then corrected in one linear gain (the voice keeps its dynamics).
LOUDNORM="I=-16:TP=-1.5:LRA=11"
MEASURED="$(ffmpeg -hide_banner -nostats -i out/raw.mov -vn -af "loudnorm=${LOUDNORM}:print_format=json" -f null - 2>&1 \
  | python3 -c 'import json, sys; t = sys.stdin.read(); d = json.loads(t[t.rindex("{"):t.rindex("}") + 1])
print(":".join("measured_%s=%s" % (k, d["input_" + k]) for k in ("i", "tp", "lra", "thresh")) + ":offset=" + d["target_offset"])')"

echo "Encoding..."
ffmpeg -hide_banner -loglevel error -y -i out/raw.mov \
  -c:v libx264 -profile:v high -level:v 4.0 -pix_fmt yuv420p -preset slow -crf 15 -maxrate 8M -bufsize 16M \
  -r 30 -g 60 -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
  -af "loudnorm=${LOUDNORM}:${MEASURED}:linear=true" -c:a aac -b:a 256k -ar 48000 -ac 2 \
  -movflags +faststart "$DOCS/simplybar-promo.mp4"
ffmpeg -hide_banner -loglevel error -y -ss "$POSTER" -i out/raw.mov -frames:v 1 -q:v 3 "$DOCS/simplybar-promo-poster.jpg"

ls -lh "$DOCS"
