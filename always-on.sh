#!/bin/bash
# Keep the home iMac up and reachable, and let you drive its Claude Code from the MacBook,
# the iPhone or claude.ai/code. Run once on the iMac. Safe to run again.
set -u
say() { printf '\n=== %s ===\n' "$1"; }
if pmset -g batt 2>/dev/null | grep -q InternalBattery; then
  echo "This is a laptop. Run always-on.sh on the iMac (the always-on Mac), not here."; exit 1
fi

say "1. Never sleep, restart by itself (asks for your password once)"
sudo pmset -a sleep 0 disksleep 0 womp 1 autorestart 1 tcpkeepalive 1 powernap 1 displaysleep 15 && echo "Sleep off, display sleeps after 15 min, wakes for network, restarts after a power cut."
sudo systemsetup -setrestartfreeze on >/dev/null 2>&1 && echo "Restarts by itself if it freezes."
pmset -g | grep -E " sleep | autorestart | womp " | sed 's/^/  /'

say "2. Claude Code Remote Control, always running"
CLAUDE_BIN=""
for c in "$(command -v claude 2>/dev/null)" "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
  [ -n "$c" ] && [ -x "$c" ] && CLAUDE_BIN="$c" && break
done
if [ -z "$CLAUDE_BIN" ]; then
  echo "Claude Code isn't installed. Run: curl -fsSL https://claude.ai/install.sh | bash   then this again."; exit 1
fi
WORK="$HOME/Claude"
mkdir -p "$WORK" "$HOME/PMPBrain/logs"
PLIST="$HOME/Library/LaunchAgents/com.pmphealthcare.claude.remote.plist"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.pmphealthcare.claude.remote</string>
  <key>ProgramArguments</key>
  <array>
    <string>$CLAUDE_BIN</string><string>remote-control</string>
    <string>--name</string><string>Home iMac</string>
    <string>--spawn</string><string>same-dir</string>
    <string>--permission-mode</string><string>default</string>
  </array>
  <key>WorkingDirectory</key><string>$WORK</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>$HOME/PMPBrain/logs/remote-control.log</string>
  <key>StandardErrorPath</key><string>$HOME/PMPBrain/logs/remote-control.err</string>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
</dict>
</plist>
PL
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" && echo "Remote Control runs in ~/Claude and restarts itself if it stops."
sleep 8
if launchctl list | grep -q com.pmphealthcare.claude.remote && ! grep -qiE "error|not logged|login" "$HOME/PMPBrain/logs/remote-control.err" 2>/dev/null; then
  echo "Running. Open claude.ai/code (or the Claude app) on the MacBook or iPhone: 'Home iMac' appears there."
else
  echo "It didn't start cleanly. Last lines of the log:"; tail -5 "$HOME/PMPBrain/logs/remote-control.err" 2>/dev/null
  echo "Usually this means Claude Code needs signing in once: run 'claude' in Terminal, sign in, then run this again."
fi

say "3. Things only you can switch on"
echo "- Tailscale: sign in (menu bar icon > Log in), so the MacBook can also reach this iMac by SSH or screen sharing."
echo "- FileVault: after a power cut the iMac restarts to the login screen, and nothing above runs until you log in once."
echo "- Time Machine: plug in an external drive > System Settings > General > Time Machine."
