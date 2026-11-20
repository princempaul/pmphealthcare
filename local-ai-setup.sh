#!/bin/bash
# Free, local AI for Katrina: runs on this Mac, no Claude subscription, nothing leaves the Mac.
# Installs Ollama (the model runtime) and the right model for this Mac's memory, then optionally
# opencode (a free coding agent). Safe to run again. Needs Homebrew and macOS 14 or newer.
set -u
say() { printf '\n=== %s ===\n' "$1"; }

say "1. This Mac"
CHIP="$(uname -m)"
RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
OS="$(sw_vers -productVersion)"
echo "Chip: $CHIP   Memory: ${RAM_GB} GB   macOS: $OS"
if [ "${OS%%.*}" -lt 14 ]; then
  echo "Ollama needs macOS 14 (Sonoma) or newer. Update macOS first, then run this again."; exit 1
fi
# Biggest model that fits comfortably, first choice then fallbacks. All have tool calling in Ollama.
if [ "$CHIP" != "arm64" ]; then
  MODELS="qwen3.5:4b qwen3.5:2b"; CTX=16384
  echo "Intel Mac: the model runs on the processor only, so expect slow answers (a few words a second)."
  echo "Good for questions about your projects; not for editing code."
elif [ "$RAM_GB" -ge 32 ]; then MODELS="qwen3.6:35b qwen3.8:27b gpt-oss:20b"; CTX=65536
elif [ "$RAM_GB" -ge 24 ]; then MODELS="gpt-oss:20b qwen3.5:9b"; CTX=65536
elif [ "$RAM_GB" -ge 16 ]; then MODELS="qwen3.5:9b gemma4:12b"; CTX=32768
else MODELS="qwen3.5:4b gemma4:e4b"; CTX=16384
fi
echo "Model plan: ${MODELS%% *} (fallback: ${MODELS#* }), context ${CTX} tokens."

say "2. Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && eval "$("$b" shellenv)"; done
fi
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew isn't installed. Install it from https://brew.sh (one command), then run this again."; exit 1
fi
echo "OK: $(brew --version | head -1)"

say "3. Ollama (model runtime)"
if command -v ollama >/dev/null 2>&1 || [ -d /Applications/Ollama.app ]; then
  echo "Already installed."
else
  brew install --cask ollama-app 2>/dev/null || brew install --cask ollama 2>/dev/null || brew install ollama
fi
# Agents need a longer memory than Ollama's 4k default on smaller Macs.
launchctl setenv OLLAMA_CONTEXT_LENGTH "$CTX"
grep -q "OLLAMA_CONTEXT_LENGTH" "$HOME/.zshrc" 2>/dev/null || printf '\nexport OLLAMA_CONTEXT_LENGTH=%s  # Katrina local\n' "$CTX" >> "$HOME/.zshrc"
if [ -d /Applications/Ollama.app ]; then
  osascript -e 'quit app "Ollama"' 2>/dev/null; sleep 2; open -a Ollama
else
  brew services restart ollama >/dev/null 2>&1 || (nohup ollama serve >/dev/null 2>&1 &)
fi
for i in $(seq 1 30); do curl -s -o /dev/null http://localhost:11434/api/version && break; sleep 1; done
curl -s http://localhost:11434/api/version || { echo "Ollama didn't start. Open the Ollama app once, then run this again."; exit 1; }
echo

say "4. Model (one-time download, several GB)"
GOT=""
for m in $MODELS; do
  if ollama list | awk 'NR>1{print $1}' | grep -qx "$m"; then GOT="$m"; echo "Already have $m."; break; fi
  echo "Downloading $m ..."
  if ollama pull "$m"; then GOT="$m"; break; fi
  echo "$m didn't download; trying the next one."
done
[ -n "$GOT" ] || { echo "No model downloaded. Check the internet connection and run this again."; exit 1; }
/usr/bin/python3 - "$HOME/PMPBrain/config.json" "$GOT" <<'PY'
import json, sys
p, m = sys.argv[1], sys.argv[2]
try:
    c = json.load(open(p))
except (OSError, ValueError):
    c = {}
c.setdefault("local", {})["model"] = m
json.dump(c, open(p, "w"), indent=2)
print("Katrina Local will use", m)
PY
echo "Warming it up (first answer is the slowest)..."
ollama run "$GOT" "Reply with the single word: ready" 2>/dev/null | tail -1
ollama ps

say "5. opencode (free coding agent, optional)"
if command -v opencode >/dev/null 2>&1; then
  echo "Already installed."
elif read -r -p "Install opencode so a local model can also edit your repos? [y/N] " a && [[ "${a:-n}" =~ ^[Yy]$ ]]; then
  brew install opencode
fi
if command -v opencode >/dev/null 2>&1; then
  mkdir -p "$HOME/.config/opencode"
  if [ ! -f "$HOME/.config/opencode/AGENTS.md" ]; then
    cat > "$HOME/.config/opencode/AGENTS.md" <<'MD'
# Katrina rules (local agent)

You work for Paul, a Nurse Practitioner in Ontario. Before changing anything, run
`python3 ~/PMPBrain/brain.py xref <project>` and check every project it lists.
Read ~/PMPBrain/CONTEXT.md for what's open and how projects connect.

- No patient or resident name, initials, date of birth, health card number or health detail in any file.
- Public wording: Nurse Practitioner-led. Never doctor, physician, medical oversight or MD.
- Never commit to or push `main` of pmphealthcare.ca or pmp-portal; both go live at once.
- Nothing is sent, posted, paid or signed. Show the git diff and stop.
- Bottom line first, short, plain words.
MD
    echo "Wrote ~/.config/opencode/AGENTS.md with Katrina's rules."
  fi
  echo "Start it inside a repo with:  ollama launch opencode   (or: opencode, then pick the Ollama model)"
fi

say "Done"
echo "Ask Katrina without Claude:  katrina-local \"what's open?\"   (open a new Terminal window first)"
echo "Everything runs on this Mac. Avoid Ollama models whose name ends in -cloud: those send data out."
