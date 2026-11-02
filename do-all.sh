#!/bin/bash
# One pass of everything still open on the iMac. Safe to run again.
# Nothing is deleted. clinic-site gets a zip snapshot and a local git commit.
set -u
SRC="$(cd "$(dirname "$0")" && pwd)"
DB="$HOME/PMPBrain/brain.db"
ICLOUD="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
STAMP="$(date +%Y-%m-%d_%H%M)"
cd "$SRC"
say() { printf '\n=== %s ===\n' "$1"; }

say "1. Update PMP Brain"
echo n | ./install.sh >/dev/null 2>&1 && echo "Updated and re-ran the nightly check." || echo "install.sh failed. Run ./install.sh to see why."

say "2. Wake schedule"
pmset -g sched | grep -iE "wake|poweron" || echo "No wake set. Run: sudo pmset repeat wakeorpoweron MTWRFSU 23:25:00"

say "3. Time Machine"
TM="$(tmutil destinationinfo 2>&1)"
if echo "$TM" | grep -qi "no destinations"; then
  echo "NOT SET UP. This iMac has no Time Machine backup."
  echo "Plug in an external drive, then System Settings > General > Time Machine > Add Backup Disk."
else
  echo "$TM" | grep -E "Name|Kind" | head -4
  tmutil latestbackup 2>/dev/null || echo "(latest backup date hidden until Full Disk Access is granted, step 6)"
fi

say "4. clinic-site backup"
SITE="$(sqlite3 "$DB" "select path from projects where name='clinic-site' limit 1" 2>/dev/null)"
if [ -z "$SITE" ] || [ ! -d "$SITE" ]; then
  echo "clinic-site not found in the database."
else
  echo "Found: $SITE"
  # a) zip snapshot to the Work drive and iCloud Drive (website source, no patient data)
  ZIP="clinic-site-$STAMP.zip"
  ( cd "$(dirname "$SITE")" && zip -qr "/tmp/$ZIP" "$(basename "$SITE")" -x "*/node_modules/*" "*/.git/*" )
  for d in "/Volumes/Work/clinic/backups" "$ICLOUD/PMPBrain/backups"; do
    if mkdir -p "$d" 2>/dev/null && cp "/tmp/$ZIP" "$d/"; then echo "Snapshot saved: $d/$ZIP"; fi
  done
  rm -f "/tmp/$ZIP"
  # b) commit the 37 uncommitted files locally so the history is safe
  cd "$SITE"
  if [ -n "$(git status --porcelain)" ]; then
    git config user.email >/dev/null || git config user.email "princempaul@icloud.com"
    git config user.name  >/dev/null || git config user.name "Paul"
    git add -A && git commit -qm "Snapshot of uncommitted work ($STAMP)" && echo "Committed $(git show --stat --oneline HEAD | tail -1)"
  else
    echo "Nothing uncommitted."
  fi
  # c) put it on GitHub as a PRIVATE repo (not if secrets are tracked)
  SECRETS="$(git ls-files | grep -E '(^|/)\.env($|\.)|\.pem$|\.key$|credentials' | head -5)"
  if [ -n "$SECRETS" ]; then
    echo "NOT pushing: these look like secrets and are tracked in git:"; echo "$SECRETS"
    echo "Tell Claude; they need moving out of the repo first. The zip snapshot above is still saved."
  elif git remote get-url origin >/dev/null 2>&1; then
    git push -q -u origin HEAD && echo "Pushed to $(git remote get-url origin)"
  elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh repo create princempaul/bluewater-clinic-site --private --source . --push && echo "Created private repo princempaul/bluewater-clinic-site and pushed."
  else
    echo "To put it on GitHub (private):"
    echo "  1. Open https://github.com/new  name: bluewater-clinic-site  Private  (no README)"
    echo "  2. Then run:"
    echo "     cd \"$SITE\" && git remote add origin https://github.com/princempaul/bluewater-clinic-site.git && git push -u origin HEAD"
  fi
  cd "$SRC"
fi

say "5. Report after update"
/usr/bin/python3 "$HOME/PMPBrain/brain.py" nightly >/dev/null 2>&1
cat "$HOME/PMPBrain/reports/$(date +%F).md"

say "6. Full Disk Access"
echo "Opening the settings pane. Click +, press Cmd+Shift+G, type /usr/bin/python3, Open, switch it on."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null

say "Done"
echo "Copy everything above from '=== 1.' down and send it to Claude."
