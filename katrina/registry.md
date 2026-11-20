# Katrina's registry: the cloud side and what feeds what

Checked 2026-11-18, updated 2026-11-20 (clinic site source settled). The Macs' own projects are in `~/PMPBrain/CONTEXT.md`; this file covers what
doesn't live on a Mac. This repo is public, so there are no account ids, no figures and nothing
about patients here. Live state is always the connector, not this page.

## Sites

| Site | Served from | Leans on |
| --- | --- | --- |
| pmphealthcare.ca | GitHub Pages, `princempaul/pmphealthcare.ca`, branch `main` | Supabase edge function `web-request` for the booking form (email fallback) |
| app.pmphealthcare.ca | GitHub Pages, `princempaul/pmp-portal`, branch `main` | Supabase project `pmp-portal` for sign-in, data and functions; Jitsi for video |
| bluewatermetabolic.ca | Cloudflare Pages, account bluewatermetabolic.ca; source is the private repo `princempaul/bluewatermetabolic` | Jane for booking |
| team.bluewatermetabolic.ca | Cloudflare (team app) | D1 `bluewater-ops` |

A push to `main` on either GitHub Pages repo is live within a minute. There is no staging.

## Supabase: project `pmp-portal` (ca-central-1)

Edge functions: `web-request` (public), `secure-message-access` (public), `secure-message-send`,
`send-fax`, `create-video-room` (signed-in only).

- `web-request` is called by pmphealthcare.ca. Rename it or change what it accepts and the public
  booking form breaks.
- `secure-message-*` are called by `secure.html` in pmp-portal.
- The iMac pings the project nightly so the free tier doesn't pause it.

## Cloudflare

Three accounts: bluewatermetabolic.ca, pmphealthcare.ca, personal. No Workers, KV or R2 on any.
D1 on the bluewatermetabolic.ca account: `bluewater-ops`, `bluewater-voice`.

## GitHub (princempaul)

`pmphealthcare.ca` (public, site), `pmp-portal` (public, portal), `pmphealthcare` (public, this
brain and Katrina), `bluewatermetabolic` (private, the live clinic site; edit it here).
`bluewater-clinic-site` (private) is the old September preview build, superseded: archive it, don't
edit it. The iMac's `~/Desktop/Virtual Clinic/clinic-site` is the same old preview.

## Notion "PMP Operator" (system of record)

Briefs (one page per report per day), Launch board (open items by lane: Clinic, Documentation,
Career, Income), Project & conversation index (the cloud twin of `brain.db`), Rules.

## Scheduled tasks and the chain between them

| Task | When (Toronto) | Reads | Writes |
| --- | --- | --- | --- |
| Daily operator brief | daily 06:20 | last Nightly review, index (Health = Action), Launch board, Calendar, Gmail, QuickBooks | Briefs |
| Search Console weekly | Mon 08:41 | Search Console, Business Profile (needs Chrome on a Mac) | Briefs |
| Website health check | daily 09:00 | bluewatermetabolic.ca pages, sitemap, Jane link | `website/daily-health-check-*.md`, Briefs |
| Team app relay | daily 09:40 | health check and guideline watch output | D1 `bluewater-ops`, then team app notify |
| Search visibility check | daily 12:15 | Google and Bing (needs Chrome on a Mac) | `website/search-visibility-log.md`, Briefs |
| Google position monitor | daily 13:37 | Google | report only |
| SEO action sprint | Mon, Thu 15:11 | position monitor, visibility log, run reference | `website/seo-sprint-*.md`, Briefs |
| Guideline watch (Treatment Plan Builder) | 1st, 15th 06:52 | guideline sources | `plan-builder/guideline-watch-*.md` |
| Medical Questions index review | 10th, 24th 16:43 | guideline sources | `claude/clinical-reference-index.md` |
| Consult Note guideline refresh | 1 Feb/May/Aug/Nov 14:17 | guideline sources | `claude/00 Master Reference` |
| Monthly money close | 1st 07:20 | QuickBooks | Briefs |
| Nightly review | daily 23:30 | tasks, sessions, GitHub, Gmail, Calendar, Cloudflare; prompt in `cloud/nightly-review-prompt.md` here | index, Briefs |
| Bluewater social weekly check | Mon 14:23 (first run Nov 23) | social accounts | not yet seen |
| Weekly career & income scout | Fri 16:20 (off) | web | Briefs |
| Desktop sync progress | hourly (off) | MacBook iCloud folder | phone |

Order matters in three places:

1. Health check (09:00) before Team app relay (09:40). Move one, move the other.
2. Visibility check (12:15) and position monitor (13:37) before SEO sprint (15:11).
3. Nightly review (23:30) before the operator brief (06:20), which opens by reading it.

## On the Macs

Both run PMP Brain at 23:30 with a notification at 06:30. The iMac holds the Work drive
(`/Volumes/Work`: pmp, clinic, clinical, academic, claude, _inbox) and is the one the
Chrome-dependent tasks need. Each Mac writes a snapshot to iCloud Drive > PMPBrain > machines and
reads the other's.
