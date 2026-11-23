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
cp "$SRC/katrina/registry.md" "$DEST/registry.md"
cp "$SRC/brain/katrina_local.py" "$DEST/katrina_local.py"
cp "$SRC/brain/crew.py" "$DEST/crew.py"
echo "$SRC" > "$DEST/src-path"   # the crew keeps this checkout up to date

# Personal Assistant Katrina: the agent itself, and a `katrina` command to start her.
mkdir -p "$HOME/.claude/agents" "$DEST/bin"
cp "$SRC"/.claude/agents/katrina*.md "$HOME/.claude/agents/"

# Let Katrina and her helpers run brain.py and read ~/PMPBrain without a permission prompt each time.
/usr/bin/python3 - "$HOME/.claude/settings.json" <<'PY'
import json, os, sys
p = sys.argv[1]
try:
    with open(p) as f:
        s = json.load(f)
except FileNotFoundError:
    s = {}
except ValueError:
    print("Left ~/.claude/settings.json alone: it isn't valid JSON. Fix it and run ./install.sh again.")
    sys.exit(0)
allow = s.setdefault("permissions", {}).setdefault("allow", [])
home = os.path.expanduser("~")
for rule in ("Bash(python3 ~/PMPBrain/brain.py:*)", "Bash(python3 %s/PMPBrain/brain.py:*)" % home,
             "Bash(/usr/bin/python3 ~/PMPBrain/brain.py:*)", "Read(~/PMPBrain/**)"):
    if rule not in allow:
        allow.append(rule)
tmp = p + ".tmp"
with open(tmp, "w") as f:
    json.dump(s, f, indent=2)
os.replace(tmp, p)
print("Allowed brain.py and ~/PMPBrain reads in ~/.claude/settings.json (no prompts for lookups).")
PY
cat > "$DEST/bin/katrina" <<'KAT'
#!/bin/bash
# Start Personal Assistant Katrina. Finds Claude Code wherever it was installed.
for c in "$(command -v claude 2>/dev/null)" "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
  [ -n "$c" ] && [ -x "$c" ] && exec "$c" --agent katrina "$@"
done
echo "Claude Code isn't installed on this Mac yet. Install it with:"
echo "  curl -fsSL https://claude.ai/install.sh | bash"
echo "then type katrina again."
exit 1
KAT
chmod +x "$DEST/bin/katrina"
touch "$HOME/.zshrc"
printf '#!/bin/bash\nexec /usr/bin/python3 "$HOME/PMPBrain/katrina_local.py" "$@"\n' > "$DEST/bin/katrina-local"
chmod +x "$DEST/bin/katrina-local"
grep -q "PMPBrain/bin/katrina-local" "$HOME/.zshrc" || printf 'alias katrina-local="$HOME/PMPBrain/bin/katrina-local"  # Katrina on a local model\n' >> "$HOME/.zshrc"
grep -q "PMPBrain/bin/katrina" "$HOME/.zshrc" || printf '\nalias katrina="$HOME/PMPBrain/bin/katrina"  # Personal Assistant Katrina\n' >> "$HOME/.zshrc"
if command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ]; then
  echo "Katrina installed. Open a new Terminal window and type: katrina"
else
  echo "Katrina installed, but Claude Code isn't on this Mac yet. Run: curl -fsSL https://claude.ai/install.sh | bash"
fi
chmod +x "$DEST/brain.py"
/usr/bin/python3 "$DEST/brain.py" init

for name in nightly morning quick crew; do
  plist="$AGENTS/com.pmphealthcare.brain.$name.plist"
  sed "s#__HOME__#$HOME#g" "$SRC/launchd/com.pmphealthcare.brain.$name.plist" > "$plist"
  launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
done
echo "Scheduled: nightly 23:30, morning notification 06:30, quick update every hour, crew every 20 seconds"

# Every future Claude Code session on this Mac loads the brain's context.
mkdir -p "$HOME/.claude"
touch "$HOME/.claude/CLAUDE.md"
if ! grep -q "PMPBrain/CONTEXT.md" "$HOME/.claude/CLAUDE.md"; then
  printf '\n# PMP Brain (auto-updated nightly)\n@~/PMPBrain/CONTEXT.md\n' >> "$HOME/.claude/CLAUDE.md"
  echo "Linked ~/PMPBrain/CONTEXT.md into ~/.claude/CLAUDE.md"
fi

# Wake the iMac at 23:25 so the 23:30 run happens even if it's asleep (needs your password once).
# A MacBook is skipped: it runs the check the next time the lid opens.
if pmset -g batt 2>/dev/null | grep -q InternalBattery; then
  echo "MacBook: no wake schedule. The check runs when it's next awake."
elif pmset -g sched 2>/dev/null | grep -qiE "23:25|11:25 ?PM"; then
  echo "Wake at 23:25 already set."
elif read -r -p "Wake the iMac every night at 23:25 for the check? [Y/n] " ans && [[ "${ans:-y}" =~ ^[Yy]$ ]]; then
  sudo pmset repeat wakeorpoweron MTWRFSU 23:25:00 && echo "Wake schedule set."
fi

echo "Running the first check now (takes under a minute)..."
/usr/bin/python3 "$DEST/brain.py" nightly
/usr/bin/python3 "$DEST/brain.py" status
/usr/bin/python3 "$DEST/brain.py" machines
echo
echo "Done. Tonight's report: $DEST/reports/. Phone copy: iCloud Drive > PMPBrain > latest-nightly.md"
echo "Tip: give /usr/bin/python3 Full Disk Access (System Settings > Privacy & Security) so the Time Machine check works."
echo "Free local Katrina (no Claude needed): run ./local-ai-setup.sh once, then: katrina-local"
if ! pmset -g batt 2>/dev/null | grep -q InternalBattery; then
  echo; echo "Jane desk (works in Jane through Chrome; talk to it from the Claude app):"
  /bin/bash "$SRC/jane-desk.sh" || echo "Jane desk didn't start; run ./jane-desk.sh later."
fi
echo
echo "Katrina PA command centre: your phone pairs itself through iCloud. The code, in case you need it:"
/usr/bin/python3 "$DEST/crew.py" pair
