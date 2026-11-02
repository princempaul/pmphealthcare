#!/bin/bash
# Install PMP Brain on this Mac. Safe to run again (it updates in place).
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/PMPBrain"
AGENTS="$HOME/Library/LaunchAgents"

echo "Installing PMP Brain into $DEST"
mkdir -p "$DEST/logs" "$DEST/reports" "$DEST/backups" "$AGENTS"
cp "$SRC/brain/brain.py" "$DEST/brain.py"
[ -f "$DEST/config.json" ] || cp "$SRC/brain/config.json" "$DEST/config.json"
[ -f "$DEST/profile.md" ]  || cp "$SRC/brain/profile.md"  "$DEST/profile.md"
cp "$SRC/brain/config.json" "$DEST/config.default.json"
chmod +x "$DEST/brain.py"
/usr/bin/python3 "$DEST/brain.py" init

for name in nightly morning; do
  plist="$AGENTS/com.pmphealthcare.brain.$name.plist"
  sed "s#__HOME__#$HOME#g" "$SRC/launchd/com.pmphealthcare.brain.$name.plist" > "$plist"
  launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
done
echo "Scheduled: nightly 23:30, morning notification 06:30"

# Every future Claude Code session on this Mac loads the brain's context.
mkdir -p "$HOME/.claude"
touch "$HOME/.claude/CLAUDE.md"
if ! grep -q "PMPBrain/CONTEXT.md" "$HOME/.claude/CLAUDE.md"; then
  printf '\n# PMP Brain (auto-updated nightly)\n@~/PMPBrain/CONTEXT.md\n' >> "$HOME/.claude/CLAUDE.md"
  echo "Linked ~/PMPBrain/CONTEXT.md into ~/.claude/CLAUDE.md"
fi

# Wake the iMac at 23:25 so the 23:30 run happens even if it's asleep (needs your password once).
if pmset -g sched 2>/dev/null | grep -qiE "23:25|11:25 ?PM"; then
  echo "Wake at 23:25 already set."
elif read -r -p "Wake the iMac every night at 23:25 for the check? [Y/n] " ans && [[ "${ans:-y}" =~ ^[Yy]$ ]]; then
  sudo pmset repeat wakeorpoweron MTWRFSU 23:25:00 && echo "Wake schedule set."
fi

echo "Running the first check now (takes under a minute)..."
/usr/bin/python3 "$DEST/brain.py" nightly
/usr/bin/python3 "$DEST/brain.py" status
echo
echo "Done. Tonight's report: $DEST/reports/. Phone copy: iCloud Drive > PMPBrain > latest-nightly.md"
echo "Tip: give /usr/bin/python3 Full Disk Access (System Settings > Privacy & Security) so the Time Machine check works."
