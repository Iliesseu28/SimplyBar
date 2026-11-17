#!/bin/zsh
# Installs the week-long SimplyBar probe as a launchd agent (one measurement a minute, stops by itself after 7 days).
#   zsh tools/probe/install.sh            install or update, then take a first measurement
#   zsh tools/probe/install.sh --remove   stop and remove the agent (the data stays)
# Data and report: ~/Library/Application Support/SimplyBarProbe (report: python3 report.py in that folder).
set -euo pipefail

HERE=${0:A:h}
DATA="$HOME/Library/Application Support/SimplyBarProbe"
LABEL=fr.simplibot.simplybar.probe
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
if [[ ${1:-} == --remove ]]; then
  rm -f "$PLIST"
  echo "Probe removed. Data kept in $DATA"
  exit 0
fi

mkdir -p "$DATA"
cp "$HERE/probe.py" "$HERE/report.py" "$DATA/"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string><string>-I</string><string>$DATA/probe.py</string>
  </array>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>Nice</key><integer>10</integer>
  <key>LowPriorityIO</key><true/>
  <key>StandardErrorPath</key><string>$DATA/probe.err</string>
</dict></plist>
PLIST
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "gui/$UID" "$PLIST"
echo "Probe installed: $DATA"
