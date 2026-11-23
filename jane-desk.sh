#!/bin/bash
# Jane desk: an always-on Claude session on the iMac that works in Jane App through Claude in Chrome.
# Paul talks to it from the Claude app on his phone (Remote Control: "Jane desk (iMac)").
# Safe to run again. Pass the clinic's Jane address once:  ./jane-desk.sh https://yourclinic.janeapp.com
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DESK="$HOME/Jane"
mkdir -p "$DESK" "$HOME/PMPBrain/logs"
cp "$SRC/jane/CLAUDE.md" "$DESK/CLAUDE.md"
cp "$SRC/jane/settings.json" "$HOME/PMPBrain/jane-settings.json"     # outside ~/Jane, so the session can't change it
if [ -n "${1:-}" ]; then echo "$1" > "$DESK/jane-url.txt"; fi
CLAUDE_BIN=""
for c in "$(command -v claude 2>/dev/null)" "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
  [ -n "$c" ] && [ -x "$c" ] && CLAUDE_BIN="$c" && break
done
[ -n "$CLAUDE_BIN" ] || { echo "Claude Code isn't installed."; exit 1; }
PLIST="$HOME/Library/LaunchAgents/com.pmphealthcare.jane.plist"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.pmphealthcare.jane</string>
  <key>ProgramArguments</key>
  <array>
    <string>$CLAUDE_BIN</string><string>remote-control</string>
    <string>--name</string><string>Jane desk (iMac)</string>
    <string>--spawn</string><string>same-dir</string>
    <string>--chrome</string>
    <string>--settings</string><string>$HOME/PMPBrain/jane-settings.json</string>
    <string>--permission-mode</string><string>default</string>
  </array>
  <key>WorkingDirectory</key><string>$DESK</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>$HOME/PMPBrain/logs/jane-desk.log</string>
  <key>StandardErrorPath</key><string>$HOME/PMPBrain/logs/jane-desk.err</string>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
</dict>
</plist>
PL
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Jane desk is running. In the Claude app on your phone: Code > 'Jane desk (iMac)'."
echo "Keep Chrome open on the iMac with Jane signed in (tick 'Remember me' / 'Stay signed in' if Jane offers it)."
[ -f "$DESK/jane-url.txt" ] || echo "Tip: run once with your Jane address so it can reopen Jane: ./jane-desk.sh https://yourclinic.janeapp.com"
