# PMP Brain and Personal Assistant Katrina

One database for every project and Claude conversation, on the iMac and the MacBook Pro, checked
every night at 23:30, with a short brief every morning. Katrina is the agent that sits on top of
it and runs the projects.

## Katrina

Open Terminal on either Mac and type `katrina`. She starts already knowing every project on both
Macs, how they connect, what's open and what was decided. Inside any other Claude Code session,
ask for her by name ("have Katrina check what's open").

- Her instructions: `.claude/agents/katrina.md` (installed to `~/.claude/agents/`)
- Her helpers, picked by cost: `katrina-scout` (Haiku, read-only lookups), `katrina-builder`
  (Sonnet, scoped changes on a branch), `katrina-checker` (Sonnet, reviews before anything is
  pushed). Katrina plans and checks; the helpers do the legwork, so most tokens go to the
  cheaper models.
- The installer allows `brain.py` and reads of `~/PMPBrain` in `~/.claude/settings.json`, so
  lookups don't stop for a permission prompt.
- Her memory: `~/PMPBrain` (below)
- The cloud side she watches: `katrina/registry.md`

```bash
python3 ~/PMPBrain/brain.py xref                 # the whole map: each shared piece and who uses it
python3 ~/PMPBrain/brain.py xref pmp-portal      # one project: where it is on each Mac, what it leans on
python3 ~/PMPBrain/brain.py xref web-request     # one service: every project that breaks if it changes
python3 ~/PMPBrain/brain.py machines             # when each Mac last checked in
python3 ~/PMPBrain/brain.py note pmp-portal "Keep web-request public"   # a decision, shared to the other Mac
```

### How the cross-referencing works

Every night each Mac reads the text files of each project (never the clinical lane, never `.env`
files) and counts mentions of the services listed under `resources` in `config.json`: domains, the
Supabase project and its functions, Jane, Cloudflare, Notion, other repos. It keeps the file name
where it found the mention, not the text. Links that can't be read from files (a scheduled task
that writes to a database, say) are written down under `links`. Add your own to either list.

### Two Macs

Each Mac keeps its own full database. After the nightly check it writes a snapshot (project list,
git state, open alerts, notes; no conversation text) to iCloud Drive > PMPBrain > machines, and
reads the other Mac's. So either one can tell you that the portal has uncommitted work on the
other, before you edit it in two places. To keep it off iCloud, set `shared_dir` in
`~/PMPBrain/config.json` to a Syncthing folder on both Macs.

Lookups are local: a full-text index in the database. Nothing waits on a network.

### Keeping it current and cheap

- **Hourly refresh.** `brain.py quick` runs every hour on each Mac: git state, new conversations,
  cross-references, the other Mac's snapshot, the search index. Projects that haven't changed are
  skipped, so it takes about a second. The full check with health alerts still runs at 23:30.
- **Short context.** `~/PMPBrain/CONTEXT.md` is loaded into every Claude Code session, so it is
  capped (6,000 characters, `limits.context_chars`): your rules, what's open, project names, the
  shared pieces, the latest decisions. Everything else is in `~/PMPBrain/FULL.md` and the database,
  read only when a question needs it.
- **One command instead of reading files.** `brain.py open` lists everything that needs attention
  on both Macs. `xref` and `search` answer most "where is" and "what touches" questions in a few
  lines. Katrina is told to use these before opening any file, and to write a note after each
  decision so no later session works it out again.

It has two halves that cover each other:

| Part | Runs where | When | What it does |
| --- | --- | --- | --- |
| `brain/brain.py` | iMac (launchd) | 23:30 | Scans project folders and git repos, indexes Claude Code conversations from `~/.claude/projects`, sorts everything into categories, runs the checks below, writes `~/PMPBrain/CONTEXT.md` and a nightly report, backs up the database |
| `brain.py brief` | iMac (launchd) | 06:30 | Mac notification: "All clear", or the first thing that needs you |
| Nightly review | Claude cloud scheduled task | 23:30 | Checks scheduled tasks, Claude sessions, GitHub, Gmail alerts, calendar, Cloudflare. Updates the Notion "Project & conversation index" and files "Nightly review — date" in Briefs |
| Daily operator brief | Claude cloud scheduled task | 06:20 every day | Reads last night's review first, then calendar, inbox, QuickBooks and the Launch board. Push to your phone |

## Install on each Mac (about 2 minutes, same steps on the iMac and the MacBook Pro)

```bash
cd ~ && git clone -b claude/project-database-daily-agent-6ihxzr https://github.com/princempaul/pmphealthcare.git pmp-brain-src
cd pmp-brain-src && ./install.sh
```

The installer:

1. copies the program to `~/PMPBrain`
2. schedules the 23:30 check and the 06:30 notification
3. adds `@~/PMPBrain/CONTEXT.md` to `~/.claude/CLAUDE.md`, so every Claude Code session on the
   iMac starts already knowing your projects, rules and recent work
4. installs Katrina and the `katrina` command
5. asks once (with your password) to wake the iMac at 23:25 so the check runs even when it's
   asleep. The MacBook is not woken; it runs the check when the lid next opens
6. runs the first check straight away

Then give `/usr/bin/python3` Full Disk Access (System Settings > Privacy & Security > Full Disk
Access) so the Time Machine check can read the backup date.

One-pass fix-up (update, wake check, Time Machine, clinic-site backup, Full Disk Access):
`cd ~/pmp-brain-src && git pull -q && ./do-all.sh`

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
dates and ID numbers stripped. Two things leave the Mac, both into your own iCloud Drive: the
nightly report (counts and alerts) and the snapshot for the other Mac (project names and paths, git
state, alerts, notes). Neither holds conversation text. A note that reads like patient detail is
refused. This repo is public, so the database,
reports and backups are git-ignored and never committed.

## Limits

- Claude desktop and claude.ai chats live on Anthropic's servers, not on the Mac, so the local
  program can't read them. The cloud nightly review covers Claude Code cloud sessions; ordinary
  claude.ai chats aren't listed by any tool yet.
- If the iMac is off (not just asleep) at 23:30, the check runs the next time it starts up.

Remove the schedule any time with `./uninstall.sh` (your database stays).
