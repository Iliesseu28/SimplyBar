#!/bin/zsh
# Rebuilds every screenshot of SimplyBar in the given languages, in one command:
#
#   zsh tools/screenshots/make.sh              # en fr
#   zsh tools/screenshots/make.sh en fr de ja  # a list of languages (codes of the string catalog)
#   zsh tools/screenshots/make.sh all          # every language of Shared/Localizable.xcstrings
#   zsh tools/screenshots/make.sh --video <folder>  # English assets of the promo video (tools/promo-video),
#                                                   # add --settings-only to redraw the settings window alone
#
# Output:
#   docs/images/{overview,menubar,popups,widgets}.png   English, for the README and the site (no title)
#   docs/images/{overview,menubar,popups,widgets}-fr.png French (other languages: DOCS_LANGS="en fr de")
#   interne/appstore-screenshots/<lang>/01.png ... 05.png   Mac App Store, 2880 x 1800, with a title
#
# How: the real SwiftUI views of the app and of the widgets are compiled, from copies of their sources, into a
# small renderer that is not sandboxed and not part of the app. It draws them with demo numbers into transparent
# PNGs (renderer/), then compose.py lays them out on a drawn desktop and writes the titles of titles.json.
# Needs Xcode and Python 3 with Pillow (raqm for Arabic and Hebrew titles).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL="$ROOT/tools/screenshots"
WORK="${TMPDIR:-/tmp}/simplybar-screenshots"
APP="$WORK/Renderer.app/Contents"
LOG="$ROOT/build/screenshots-renderer.log"
mkdir -p "$ROOT/build"

VIDEO_OUT=""
if [[ "${1:-}" == "--video" ]]; then
  [[ -n "${2:-}" ]] || { echo "usage: make.sh --video <output folder>" >&2; exit 2; }
  mkdir -p "$2"
  VIDEO_OUT="$(cd "$2" && pwd)"
  VIDEO_FLAGS=(--video ${3:+"$3"})  # --settings-only redraws the settings window alone
  set -- en
fi
if [[ $# -eq 0 ]]; then
  set -- en fr
elif [[ "$1" == "all" ]]; then
  set -- ${(f)"$(python3 "$TOOL/compose.py" --list-catalog-languages "$ROOT/Shared/Localizable.xcstrings")"}
fi

# Fail before the build when a language has no title or demo name.
python3 "$TOOL/compose.py" --check "$@"

echo "Building the renderer..."
rm -rf "$WORK/src" "$WORK/Renderer.app"
mkdir -p "$WORK/src" "$APP/MacOS" "$APP/Resources/en.lproj"
cp "$ROOT"/Shared/*.swift "$ROOT"/Core/*.swift "$ROOT"/SimplyBarWidgets/*.swift "$WORK/src/"
for file in "$ROOT"/SimplyBar/*.swift; do
  # The app's entry point stays out: the renderer has its own.
  [[ "$(basename "$file")" == "SimplyBarApp.swift" ]] || cp "$file" "$WORK/src/"
done

# Three edits of the copies, visibility only, so the renderer can feed demo numbers and draw every widget size:
# the widget bundle loses its @main, the monitor's samples become settable, the Storage views leave file scope.
sed -i '' '/^@main$/d' "$WORK/src/SimplyBarWidgets.swift"
sed -i '' -E 's/private\(set\) var /var /' "$WORK/src/SystemMonitor.swift"
sed -i '' -E 's/^private struct /struct /' "$WORK/src/StorageWidget.swift"
if grep -q '^@main' "$WORK/src/SimplyBarWidgets.swift" || grep -q 'private(set) var' "$WORK/src/SystemMonitor.swift" \
  || grep -qE '^private struct (SmallStorageView|StorageListView)' "$WORK/src/StorageWidget.swift"; then
  echo "The sources changed shape: update the edits in tools/screenshots/make.sh" >&2
  exit 1
fi
cp "$TOOL"/renderer/*.swift "$WORK/src/"

# The app's build settings: Swift 6 with approachable concurrency, macOS 14.
if ! xcrun swiftc -swift-version 6 \
  -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances \
  -target arm64-apple-macos14.0 -parse-as-library -Onone \
  "$WORK"/src/*.swift -o "$APP/MacOS/Renderer" > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" | head -20 >&2
  echo "Renderer build failed, full log: $LOG" >&2
  exit 1
fi

# The string catalog, compiled as Xcode does, so the views read their translations.
xcrun xcstringstool compile "$ROOT/Shared/Localizable.xcstrings" --output-directory "$APP/Resources" >> "$LOG" 2>&1
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>fr.simplibot.simplybar.screenshot-renderer</string>
<key>CFBundleExecutable</key><string>Renderer</string>
<key>CFBundleName</key><string>SimplyBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

if [[ -n "$VIDEO_OUT" ]]; then
  # The video's assets: English, drawn at 4 pixels per point. The settings window must be the active one: the
  # renderer runs as a regular app launched by `open` (macOS brings that one to the front, not a process started
  # from a shell), and writes on the internal disk (launched that way, it would ask access to an external volume).
  plutil -replace LSUIElement -bool NO "$APP/Info.plist"
  STAGE="$WORK/video"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  if [[ "${3:-}" == "--settings-only" ]]; then
    # The other sizes come from the full run before: the renderer adds the settings to them.
    [[ -f "$VIDEO_OUT/video-assets.json" ]] && cp "$VIDEO_OUT/video-assets.json" "$STAGE/"
  fi
  python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))["en"]["demo"]))' "$TOOL/titles.json" \
    > "$STAGE/demo.json"
  # `open -W` waits without a limit: a system prompt left unanswered would block it, so a watchdog ends it.
  ( sleep 300; pkill -f "$WORK/Renderer.app/Contents/MacOS/" ) &
  WATCHDOG=$!
  open -W -n "$WORK/Renderer.app" \
    --args "$STAGE" "$STAGE/demo.json" 4 ltr "${VIDEO_FLAGS[@]}" -AppleLanguages "(en)" -AppleLocale en_US
  kill $WATCHDOG 2>/dev/null || true
  if ! grep -q "^rendered " "$STAGE/render.log" 2>/dev/null; then
    tail -20 "$STAGE/render.log" >&2 || true
    echo "Video assets failed, full log: $STAGE/render.log" >&2
    exit 1
  fi
  if [[ "${3:-}" != "--settings-only" ]]; then
    # A full run replaces everything: no image of an earlier run stays behind.
    rm -f "$VIDEO_OUT"/*.png(N) "$VIDEO_OUT/video-assets.json"
  fi
  cp "$STAGE"/*.png "$STAGE/video-assets.json" "$VIDEO_OUT/"
  grep -E "^Renderer:|^rendered " "$STAGE/render.log"
  exit 0
fi

python3 "$TOOL/compose.py" --root "$ROOT" --work "$WORK" --renderer "$APP/MacOS/Renderer" "$@"
