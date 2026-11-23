# Katrina PA: the control tower

One SwiftUI app for iPhone, iPad and Mac (iOS 17+, macOS 14+). It oversees every Mac, every Claude
Code session, the work you delegate, your GitHub repos and builds, and your websites. You decide,
Katrina dispatches, and the Macs do the work.

| Tab | What it does |
| --- | --- |
| Tower | One board for everything that needs you, ranked: approvals, PRs ready to merge, failing builds, Claude sessions waiting on you, sites down, a Mac off the radar. Then what's in flight, fleet health, websites, the brief. One-tap actions. |
| Dispatch | Talk to Katrina. She checks the whole fleet live and lines up orders (missions, merges, re-runs) as cards. Nothing happens until you tap Approve. |
| Missions | Work you've delegated. Brief a mission, follow its reports, send follow-ups, approve the push, open the PR, or discard it. |
| Projects | Every project on both Macs with live GitHub status, recent Claude sessions, and "send a mission here". |
| Settings | Pairing, brain folder, GitHub token, Anthropic key, sites to watch, alerts, theme, notes. |

## How it works

```
 iPhone (Katrina PA)                 iCloud Drive/PMPBrain                 iMac (always on)
 ───────────────────                 ─────────────────────                 ────────────────
 Tower reads  ◄────────────── fleet/<Mac>.json  ◄──── every 20 s ──────  crew.py (launchd)
                              machines/<Mac>.json ◄── every hour ──────  brain.py
 Missions / Dispatch ─signed─► orders/<id>.json  ────────────────────►  crew.py runs:
                                                                          claude -p … (your subscription)
 GitHub API (token) ◄──► PRs, builds, merge, open PR
 Websites ◄── GET, timed
```

- **Missions** run Claude Code headless on the Mac with `--permission-mode dontAsk` and a fixed tool list.
  *Look* missions read and report. *Work* missions edit and commit in a separate git worktree on a
  `katrina/<id>` branch, so your own working copy is never touched. Pushing waits for your Approve.
- **Orders are signed** (HMAC-SHA256 with the pairing code). The Mac drops anything unsigned, replayed
  or older than a day, and only runs missions inside projects the brain already knows.
- **No patient data**: orders and notes that read like patient detail are refused on the phone and on
  the Mac. The Macs share session titles and status only, never conversation text or file contents;
  clinical sessions show as "Clinical session (content not stored)".

## Set up

1. On the iMac: `cd ~/pmp-brain-src && git pull && ./install.sh`. It starts the crew and prints a
   pairing code (later: `python3 ~/PMPBrain/crew.py pair`).
2. MacBook too? Run the installer there, then `python3 ~/PMPBrain/crew.py pair <the iMac's code>`.
3. In the app: Settings > Pair with your Macs (the code), choose the PMPBrain folder, add a GitHub
   fine-grained token (Pull requests and Actions: read and write; Contents: read) and an Anthropic API
   key for Dispatch.

## Costs

The Tower, Missions list, Projects and GitHub views use no AI. Dispatch uses the Anthropic API key
(billed per use; Opus 5.5 at low effort by default, with a cached system prompt). Missions run on the
Mac under your Claude subscription.

## Build and ship

CI builds every push (`.github/workflows/katrina-app.yml`). Actions > Katrina app build > Run workflow
uploads a new TestFlight build; "testers only" just refreshes the TestFlight group and invite.
Locally: `brew install xcodegen && cd apps/Katrina && xcodegen && open Katrina.xcodeproj`.
