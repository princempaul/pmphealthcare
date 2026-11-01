#!/bin/bash
# Stops the schedule. Keeps ~/PMPBrain (your database) unless you delete it yourself.
for name in nightly morning; do
  plist="$HOME/Library/LaunchAgents/com.pmphealthcare.brain.$name.plist"
  launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
  rm -f "$plist"
done
sed -i '' '/PMP Brain (auto-updated nightly)/d;/PMPBrain\/CONTEXT.md/d' "$HOME/.claude/CLAUDE.md" 2>/dev/null || true
echo "PMP Brain schedule removed. Database left at ~/PMPBrain."
