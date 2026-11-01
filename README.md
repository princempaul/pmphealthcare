# PMP Brain

One database for every project and Claude conversation, checked every night at 23:30, with a
short brief every morning.

It has two halves that cover each other:

| Part | Runs where | When | What it does |
| --- | --- | --- | --- |
| `brain/brain.py` | iMac (launchd) | 23:30 | Scans project folders and git repos, indexes Claude Code conversations from `~/.claude/projects`, sorts everything into categories, runs the checks below, writes `~/PMPBrain/CONTEXT.md` and a nightly report, backs up the database |
| `brain.py brief` | iMac (launchd) | 06:30 | Mac notification: "All clear", or the first thing that needs you |
| Nightly review | Claude cloud scheduled task | 23:30 | Checks scheduled tasks, Claude sessions, GitHub, Gmail alerts, calendar, Cloudflare. Updates the Notion "Project & conversation index" and files "Nightly review — date" in Briefs |
| Daily operator brief | Claude cloud scheduled task | 06:20 every day | Reads last night's review first, then calendar, inbox, QuickBooks and the Launch board. Push to your phone |

## Install on the iMac (about 2 minutes)

```bash
cd ~ && git clone -b claude/project-database-daily-agent-6ihxzr https://github.com/princempaul/pmphealthcare.git pmp-brain-src
cd pmp-brain-src && ./install.sh
```

The installer:

1. copies the program to `~/PMPBrain`
2. schedules the 23:30 check and the 06:30 notification
3. adds `@~/PMPBrain/CONTEXT.md` to `~/.claude/CLAUDE.md`, so every Claude Code session on the
   iMac starts already knowing your projects, rules and recent work
4. asks once (with your password) to wake the iMac at 23:25 so the check runs even when it's asleep
5. runs the first check straight away

Then give `/usr/bin/python3` Full Disk Access (System Settings > Privacy & Security > Full Disk
Access) so the Time Machine check can read the backup date.

To update later: `cd ~/pmp-brain-src && git pull && ./install.sh`. Your `config.json` and
`profile.md` in `~/PMPBrain` are kept.

## What the nightly check verifies

- database integrity, plus 14 days of rolling backups
- the previous run actually happened (catches a sleeping or switched-off iMac)
- git repos with uncommitted work left 2+ days, commits never pushed, repos with no remote
- disk space under 15%, Time Machine older than 3 days, Syncthing not running, macOS updates waiting
- Downloads clutter
- the PHI wall: anything in the database that looks like a health card number or date of birth
  gets wiped and flagged

## Commands

```bash
python3 ~/PMPBrain/brain.py status          # counts by category, last run
python3 ~/PMPBrain/brain.py search seo      # find a project, conversation or fact
python3 ~/PMPBrain/brain.py nightly         # run the check now
```

Reports: `~/PMPBrain/reports/YYYY-MM-DD.md`. Phone copy: iCloud Drive > PMPBrain > latest-nightly.md.

## Categories

Bluewater clinic, PMP Healthcare corp, Websites & SEO, Portal & tech, Clinical documentation,
Money & accounting, Career & income, Operator & automation, Home & personal. Edit the keyword
lists in `~/PMPBrain/config.json`; pin a project to a category under `project_overrides`.

## Patient privacy

Conversations that look clinical are stored as "Clinical session (content not stored)" with a
date and nothing else. Other conversations keep a short first line with emails, phone numbers,
dates and ID numbers stripped. Nothing leaves the Mac except the nightly report copy in your own
iCloud Drive, and that file holds counts and alerts only. This repo is public, so the database,
reports and backups are git-ignored and never committed.

## Limits

- Claude desktop and claude.ai chats live on Anthropic's servers, not on the Mac, so the local
  program can't read them. The cloud nightly review covers Claude Code cloud sessions; ordinary
  claude.ai chats aren't listed by any tool yet.
- If the iMac is off (not just asleep) at 23:30, the check runs the next time it starts up.

Remove the schedule any time with `./uninstall.sh` (your database stays).
