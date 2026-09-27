#!/bin/zsh
# Builds SimplyBar in Release, installs it in /Applications, launches it and checks the widget extension.
# Usage: zsh tools/install.sh
# A sandboxed binary started from an external disk may crash at launch: only the /Applications copy is run.
# DERIVED_DATA overrides where Xcode builds (default: build/DerivedData in the repository).
set -euo pipefail

ROOT=${0:A:h:h}
DERIVED=${DERIVED_DATA:-$ROOT/build/DerivedData}
BUILT=$DERIVED/Build/Products/Release/SimplyBar.app
TARGET=/Applications/SimplyBar.app
BUNDLE_ID=fr.simplibot.simplybar
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
LOG=$ROOT/build/release.log

mkdir -p "$ROOT/build"
echo "Build Release (journal : $LOG)"
if ! xcodebuild build -project "$ROOT/SimplyBar.xcodeproj" -scheme SimplyBar -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" > "$LOG" 2>&1; then
  grep -nE "error:|warning: " "$LOG" | head -40
  exit 1
fi
grep -nE "warning: " "$LOG" | head -20 || true

# Quit the running copy.
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
pkill -x SimplyBar >/dev/null 2>&1 || true

# Only the /Applications copy must be known to the system: forget the ones in DerivedData.
for config in Debug Release; do
  copy=$DERIVED/Build/Products/$config/SimplyBar.app
  [[ -d $copy ]] || continue
  pluginkit -r "$copy/Contents/PlugIns/SimplyBarWidgets.appex" >/dev/null 2>&1 || true
  "$LSREGISTER" -u "$copy" >/dev/null 2>&1 || true
done

rm -rf "$TARGET"
ditto "$BUILT" "$TARGET"
# ditto keeps the build date: a fresh date makes Finder and the Dock drop their cached icon.
touch "$TARGET" "$TARGET/Contents/Info.plist"
"$LSREGISTER" -f -R "$TARGET"
codesign --verify --deep --strict "$TARGET"
open "$TARGET"

for _ in {1..15}; do
  pluginkit -m -v | grep -q "$BUNDLE_ID.widgets.*$TARGET" && break
  sleep 1
done
pluginkit -m -v | grep -i "$BUNDLE_ID" || { echo "Widget non enregistré" >&2; exit 1; }
