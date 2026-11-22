#!/bin/bash
# Rebuild pmp-brain-installer.command (one double-clickable file) from this folder.
set -euo pipefail
cd "$(dirname "$0")"
TMP="$(mktemp -d)"; mkdir "$TMP/pmp-brain"
cp -R brain katrina launchd .claude install.sh uninstall.sh do-all.sh local-ai-setup.sh always-on.sh README.md "$TMP/pmp-brain/"
find "$TMP" -name __pycache__ -prune -exec rm -rf {} +
{
  cat <<'HEAD'
#!/bin/bash
# PMP Brain + Katrina installer. Double-click on the iMac and on the MacBook Pro,
# or run: bash pmp-brain-installer.command
set -e
DEST="$HOME/pmp-brain-src"
rm -rf "$DEST.tmp" && mkdir -p "$DEST.tmp"
sed '1,/^__ARCHIVE_BELOW__$/d' "$0" | base64 --decode | tar xz -C "$DEST.tmp"
rm -rf "$DEST" && mv "$DEST.tmp/pmp-brain" "$DEST" && rm -rf "$DEST.tmp"
cd "$DEST" && ./install.sh
exit 0
__ARCHIVE_BELOW__
HEAD
  tar czf - -C "$TMP" pmp-brain | base64
} > pmp-brain-installer.command
chmod +x pmp-brain-installer.command
rm -rf "$TMP"
echo "Built pmp-brain-installer.command"
