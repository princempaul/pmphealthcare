#!/usr/bin/env python3
"""PMP Brain: one local database of Paul's projects and Claude conversations.

Runs on the iMac. Standard library only (works with the macOS /usr/bin/python3).

  brain.py init       create ~/PMPBrain and the database
  brain.py nightly    scan, categorize, verify, write report + CONTEXT.md (launchd, 23:30)
  brain.py brief      morning brief from last night's run (launchd, 06:30)
  brain.py status     print what's in the database
  brain.py search X   search projects and conversations

Nothing here sends email, posts, or calls an outside service. It reads local
files and writes into ~/PMPBrain only (plus one import line in ~/.claude/CLAUDE.md
that install.sh adds).
"""

import datetime as dt
import glob
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys

HOME = os.path.expanduser("~")
BASE = os.environ.get("PMP_BRAIN_HOME", os.path.join(HOME, "PMPBrain"))
DB = os.path.join(BASE, "brain.db")
CONFIG = os.path.join(BASE, "config.json")
REPORTS = os.path.join(BASE, "reports")
BACKUPS = os.path.join(BASE, "backups")
CONTEXT = os.path.join(BASE, "CONTEXT.md")
ICLOUD = os.path.join(HOME, "Library", "Mobile Documents", "com~apple~CloudDocs")
HERE = os.path.dirname(os.path.abspath(__file__))

SCHEMA = """
CREATE TABLE IF NOT EXISTS projects (
  path TEXT PRIMARY KEY,
  name TEXT,
  category TEXT,
  kind TEXT,               -- git / folder
  branch TEXT,
  remote TEXT,
  dirty_files INTEGER,
  unpushed INTEGER,
  last_commit TEXT,
  last_commit_msg TEXT,
  last_modified TEXT,
  has_claude_md INTEGER,
  first_seen TEXT,
  last_seen TEXT,
  active INTEGER DEFAULT 1
);
CREATE TABLE IF NOT EXISTS conversations (
  session_id TEXT PRIMARY KEY,
  source TEXT,             -- claude-code
  project_path TEXT,
  title TEXT,
  category TEXT,
  started TEXT,
  ended TEXT,
  messages INTEGER,
  summary TEXT,            -- redacted, short; empty for clinical
  phi_risk INTEGER DEFAULT 0,
  file TEXT,
  file_mtime REAL
);
CREATE TABLE IF NOT EXISTS facts (
  key TEXT PRIMARY KEY,
  value TEXT,
  category TEXT,
  updated TEXT
);
CREATE TABLE IF NOT EXISTS alerts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_date TEXT,
  level TEXT,              -- ACTION / WATCH / INFO
  area TEXT,
  message TEXT,
  resolved INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  started TEXT,
  finished TEXT,
  kind TEXT,
  ok INTEGER,
  projects INTEGER,
  conversations_new INTEGER,
  alerts INTEGER,
  notes TEXT
);
CREATE INDEX IF NOT EXISTS conv_cat ON conversations(category);
CREATE INDEX IF NOT EXISTS conv_end ON conversations(ended);
CREATE INDEX IF NOT EXISTS alerts_run ON alerts(run_date);
"""

# Anything that looks like it could identify a patient never gets stored.
PHI_PATTERNS = [
    re.compile(r"\b\d{4}[- ]?\d{3}[- ]?\d{3}(?:[- ]?[A-Z]{2})?\b"),          # Ontario health card
    re.compile(r"\b(19|20)\d{2}[-/](0[1-9]|1[0-2])[-/](0[1-9]|[12]\d|3[01])\b"),  # dates (DOB)
    re.compile(r"\b(0?[1-9]|[12]\d|3[01])[-/](0?[1-9]|1[0-2])[-/](19|20)\d{2}\b"),
    re.compile(r"\b(DOB|MRN|HCN|OHIP)\b[:#\s]*\S+", re.I),
    re.compile(r"\b(room|rm|bed)\s*#?\s*\d+[A-Z]?\b", re.I),
    re.compile(r"\b(Mr|Mrs|Ms|Miss)\.?\s+[A-Z][a-z]+"),
    re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+"),
    re.compile(r"\+?1?[ -.(]*\d{3}[ -.)]*\d{3}[ -.]*\d{4}\b"),
]
CLINICAL_WORDS = re.compile(
    r"\b(resident|patient|pcc|emar|prn|chart|progress note|narrative note|"
    r"medication review|labs?|diagnos\w*|mg\b|dose|orders?|vitals|bp\b|"
    r"inr|a1c|egfr|wound|fall|delirium|dementia)\b", re.I)


def now():
    return dt.datetime.now().replace(microsecond=0)


def today():
    return now().date().isoformat()


def redact(text):
    for p in PHI_PATTERNS:
        text = p.sub("[redacted]", text)
    return text


# ---------------------------------------------------------------- config / db

def _merge(base, mine):
    """Your config.json wins on values; lists are combined so new defaults still arrive."""
    if isinstance(base, dict) and isinstance(mine, dict):
        out = dict(base)
        for k, v in mine.items():
            out[k] = _merge(base[k], v) if k in base else v
        return out
    if isinstance(base, list) and isinstance(mine, list):
        return base + [x for x in mine if x not in base]
    return mine


def load_config():
    cfg = {}
    for src in (os.path.join(BASE, "config.default.json"), os.path.join(HERE, "config.json"), CONFIG):
        if os.path.exists(src):
            with open(src) as f:
                cfg = _merge(cfg, json.load(f)) if cfg else json.load(f)
    cfg["scan_roots"] = [os.path.expanduser(p) for p in cfg.get("scan_roots", [])]
    return cfg


def connect():
    os.makedirs(BASE, exist_ok=True)
    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
    con.executescript(SCHEMA)
    return con


def categorize(text, cfg):
    text = (text or "").lower()
    best, score = "Uncategorized", 0
    for cat, words in cfg["categories"].items():
        s = sum(text.count(w.lower()) for w in words)
        if s > score:
            best, score = cat, s
    return best


# ---------------------------------------------------------------- projects

def run(cmd, cwd=None, timeout=20):
    try:
        out = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return out.stdout.strip()
    except Exception:
        return ""


def find_projects(cfg):
    found = set()
    skip = set(cfg.get("skip_dirs", []))
    for root in cfg["scan_roots"]:
        if not os.path.isdir(root):
            continue
        base_depth = root.rstrip("/").count("/")
        for dirpath, dirnames, filenames in os.walk(root):
            depth = dirpath.count("/") - base_depth
            dirnames[:] = [d for d in dirnames
                           if d not in skip and not (d.startswith(".") and d != ".git")]
            if ".git" in dirnames or "CLAUDE.md" in filenames:
                found.add(dirpath)
                dirnames[:] = []          # don't descend into a project
                continue
            if depth >= cfg.get("scan_depth", 3):
                dirnames[:] = []
    for p in cfg.get("extra_projects", []):
        p = os.path.expanduser(p)
        if os.path.isdir(p):
            found.add(p)
    return sorted(found)


def project_info(path, cfg):
    info = {"path": path, "name": os.path.basename(path)}
    is_git = os.path.isdir(os.path.join(path, ".git"))
    info["kind"] = "git" if is_git else "folder"
    info["has_claude_md"] = int(os.path.exists(os.path.join(path, "CLAUDE.md")))
    try:
        newest = max((os.path.getmtime(os.path.join(dp, f))
                      for dp, dn, fn in os.walk(path)
                      if "/.git" not in dp and "node_modules" not in dp
                      for f in fn[:200]), default=os.path.getmtime(path))
    except Exception:
        newest = os.path.getmtime(path)
    info["last_modified"] = dt.datetime.fromtimestamp(newest).replace(microsecond=0).isoformat()
    text = info["name"]
    if is_git:
        info["branch"] = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], path)
        info["remote"] = run(["git", "config", "--get", "remote.origin.url"], path)
        status = run(["git", "status", "--porcelain"], path)
        info["dirty_files"] = len([l for l in status.splitlines() if l.strip()])
        ahead = run(["git", "rev-list", "--count", "@{u}..HEAD"], path)
        info["unpushed"] = int(ahead) if ahead.isdigit() else (-1 if info["remote"] else 0)
        info["last_commit"] = run(["git", "log", "-1", "--format=%cI"], path)
        info["last_commit_msg"] = run(["git", "log", "-1", "--format=%s"], path)[:120]
        text += " " + info["remote"] + " " + run(["git", "log", "-20", "--format=%s"], path)
    else:
        info.update(branch="", remote="", dirty_files=0, unpushed=0,
                    last_commit="", last_commit_msg="")
    for readme in ("CLAUDE.md", "README.md"):
        fp = os.path.join(path, readme)
        if os.path.exists(fp):
            with open(fp, errors="ignore") as f:
                text += " " + f.read(4000)
    info["category"] = cfg.get("project_overrides", {}).get(info["name"]) or categorize(text, cfg)
    return info


def sync_projects(con, cfg):
    stamp = now().isoformat()
    paths = find_projects(cfg)
    con.execute("UPDATE projects SET active=0")
    for p in paths:
        i = project_info(p, cfg)
        con.execute("""
          INSERT INTO projects (path,name,category,kind,branch,remote,dirty_files,unpushed,
             last_commit,last_commit_msg,last_modified,has_claude_md,first_seen,last_seen,active)
          VALUES (:path,:name,:category,:kind,:branch,:remote,:dirty_files,:unpushed,
             :last_commit,:last_commit_msg,:last_modified,:has_claude_md,:s,:s,1)
          ON CONFLICT(path) DO UPDATE SET name=excluded.name, category=excluded.category,
             kind=excluded.kind, branch=excluded.branch, remote=excluded.remote,
             dirty_files=excluded.dirty_files, unpushed=excluded.unpushed,
             last_commit=excluded.last_commit, last_commit_msg=excluded.last_commit_msg,
             last_modified=excluded.last_modified, has_claude_md=excluded.has_claude_md,
             last_seen=excluded.last_seen, active=1
        """, dict(i, s=stamp))
    return len(paths)


# ---------------------------------------------------------------- conversations

def _text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(c.get("text", "") for c in content
                        if isinstance(c, dict) and c.get("type") == "text")
    return ""


def parse_session(fp):
    sid, cwd, title, first_user = os.path.basename(fp)[:-6], "", "", ""
    started = ended = ""
    n = 0
    words = []
    with open(fp, errors="ignore") as f:
        for line in f:
            try:
                ev = json.loads(line)
            except Exception:
                continue
            t = ev.get("type")
            if t == "summary" and ev.get("summary"):
                title = ev["summary"]
                continue
            if t not in ("user", "assistant"):
                continue
            ts = ev.get("timestamp", "")
            started = started or ts
            ended = ts or ended
            cwd = cwd or ev.get("cwd", "")
            sid = ev.get("sessionId", sid)
            msg = ev.get("message") or {}
            txt = _text_of(msg.get("content"))
            if not txt or txt.startswith("<"):
                continue
            n += 1
            if t == "user" and not first_user:
                first_user = txt
            if len(words) < 400:
                words.extend(txt.split()[:80])
    return dict(session_id=sid, project_path=cwd, title=title, first_user=first_user,
                started=started, ended=ended, messages=n, sample=" ".join(words))


def sync_conversations(con, cfg):
    roots = [os.path.join(HOME, ".claude", "projects")]
    known = {r["file"]: r["file_mtime"] for r in
             con.execute("SELECT file, file_mtime FROM conversations")}
    new = 0
    for root in roots:
        for fp in glob.glob(os.path.join(root, "*", "*.jsonl")):
            mt = os.path.getmtime(fp)
            if known.get(fp) == mt:
                continue
            s = parse_session(fp)
            if s["messages"] == 0:
                continue
            blob = " ".join([s["title"], s["first_user"], s["sample"], s["project_path"]])
            cat = categorize(blob, cfg)
            clinical = cat == "Clinical documentation" or len(CLINICAL_WORDS.findall(blob)) >= 4
            if clinical:
                cat = "Clinical documentation"
                summary = ""          # never keep clinical text
                title = s["title"] if s["title"] and not CLINICAL_WORDS.search(s["title"]) else "Clinical session (content not stored)"
            else:
                summary = redact(" ".join(s["first_user"].split()))[:220]
                title = redact(s["title"] or summary[:80])
            if fp not in known:
                new += 1
            con.execute("""
              INSERT INTO conversations (session_id,source,project_path,title,category,started,
                 ended,messages,summary,phi_risk,file,file_mtime)
              VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
              ON CONFLICT(session_id) DO UPDATE SET title=excluded.title,
                 category=excluded.category, ended=excluded.ended, messages=excluded.messages,
                 summary=excluded.summary, phi_risk=excluded.phi_risk,
                 file=excluded.file, file_mtime=excluded.file_mtime
            """, (s["session_id"], "claude-code", s["project_path"], title, cat, s["started"],
                  s["ended"], s["messages"], summary, int(clinical), fp, mt))
    return new


# ---------------------------------------------------------------- facts

def sync_facts(con, cfg):
    for k, v in cfg.get("facts", {}).items():
        con.execute("""INSERT INTO facts(key,value,category,updated) VALUES(?,?,?,?)
                       ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated=excluded.updated""",
                    (k, v["value"], v.get("category", ""), today()))


# ---------------------------------------------------------------- verification

def verify(con, cfg):
    """Return list of (level, area, message)."""
    out = []
    lim = cfg.get("limits", {})

    # database health
    ok = con.execute("PRAGMA integrity_check").fetchone()[0]
    if ok != "ok":
        out.append(("ACTION", "Database", "brain.db integrity check failed: %s. Restore from backups/." % ok))

    # last run gap
    last = con.execute("SELECT finished FROM runs WHERE kind='nightly' AND ok=1 ORDER BY id DESC LIMIT 1").fetchone()
    if last and last[0]:
        gap = now() - dt.datetime.fromisoformat(last[0])
        if gap.days >= 2:
            out.append(("WATCH", "Brain", "Last good nightly run was %d days ago. The iMac was probably asleep or off at 23:30." % gap.days))

    # projects
    stale_days = lim.get("dirty_days", 2)
    for r in con.execute("SELECT * FROM projects WHERE active=1 AND kind='git'"):
        if r["dirty_files"] and r["last_modified"]:
            age = (now() - dt.datetime.fromisoformat(r["last_modified"])).days
            if age >= stale_days:
                out.append(("WATCH", r["category"], "%s has %d uncommitted file(s), untouched %d days." % (r["name"], r["dirty_files"], age)))
        if r["unpushed"] and r["unpushed"] > 0:
            out.append(("WATCH", r["category"], "%s has %d commit(s) not pushed (branch %s)." % (r["name"], r["unpushed"], r["branch"])))
        if not r["remote"]:
            out.append(("INFO", r["category"], "%s has no remote. Nothing backs it up except this Mac." % r["name"]))

    # drives and folders that must be there (the Work volume)
    for p in cfg.get("required_paths", []):
        if not os.path.isdir(os.path.expanduser(p)):
            out.append(("ACTION", "Mac", "%s isn't mounted or is missing, so tonight's scan skipped it. Unlock/mount the Work drive." % p))

    # the _inbox lane is meant to be emptied weekly
    inbox = "/Volumes/Work/_inbox"
    if os.path.isdir(inbox):
        n = len([f for f in os.listdir(inbox) if not f.startswith(".")])
        if n > lim.get("inbox_files", 25):
            out.append(("WATCH", "Inbox (unsorted)", "%d items sitting in /Volumes/Work/_inbox. Sort them into pmp, clinic, clinical or academic." % n))

    # disk
    try:
        du = shutil.disk_usage(HOME)
        free = du.free / du.total * 100
        if free < lim.get("disk_free_pct", 15):
            out.append(("ACTION", "Mac", "Disk is %.0f%% free (%.0f GB). Clear space before it slows the Mac." % (free, du.free / 1e9)))
    except Exception:
        pass

    if sys.platform == "darwin":
        # Time Machine
        tm = run(["tmutil", "latestbackup"])
        m = re.search(r"(\d{4}-\d{2}-\d{2})-(\d{6})", tm)
        if m:
            age = (now().date() - dt.date.fromisoformat(m.group(1))).days
            if age > lim.get("backup_days", 3):
                out.append(("ACTION", "Mac", "Last Time Machine backup was %d days ago." % age))
        elif cfg.get("expect_time_machine", True):
            dest = run(["tmutil", "destinationinfo"])
            if "no destinations" in dest.lower() or not dest.strip():
                out.append(("ACTION", "Mac", "No Time Machine backup is set up. If this iMac's drive fails, everything not on GitHub or iCloud is lost. Plug in an external drive and add it in System Settings > General > Time Machine."))
            else:
                out.append(("WATCH", "Mac", "Time Machine is set up but the last backup date can't be read. Give /usr/bin/python3 Full Disk Access."))
        # Syncthing between MacBook and iMac
        if cfg.get("expect_syncthing", True) and not run(["pgrep", "-x", "syncthing"]):
            out.append(("WATCH", "Mac", "Syncthing isn't running, so MacBook and iMac files aren't syncing."))
        # pending macOS updates (cached list only, fast)
        upd = run(["defaults", "read", "/Library/Preferences/com.apple.SoftwareUpdate", "LastRecommendedUpdatesAvailable"])
        if upd.isdigit() and int(upd) > 0:
            out.append(("INFO", "Mac", "%s macOS update(s) waiting." % upd))

    # Downloads clutter
    dl = os.path.join(HOME, "Downloads")
    if os.path.isdir(dl):
        old = [f for f in os.listdir(dl)
               if not f.startswith(".") and (now().timestamp() - os.path.getmtime(os.path.join(dl, f))) > 30 * 86400]
        if len(old) > lim.get("downloads_old", 50):
            out.append(("INFO", "Mac", "%d files in Downloads older than 30 days. Worth a clear-out." % len(old)))

    # PHI wall check on the database itself
    leaks = 0
    for r in con.execute("SELECT summary, title FROM conversations"):
        blob = (r["summary"] or "") + " " + (r["title"] or "")
        if any(p.search(blob) for p in PHI_PATTERNS[:3]):
            leaks += 1
    if leaks:
        con.execute("UPDATE conversations SET summary='' WHERE phi_risk=1")
        out.append(("ACTION", "PHI wall", "%d stored conversation line(s) matched an ID/date pattern. Clinical summaries were wiped; check `brain.py search redacted`." % leaks))

    return out


# ---------------------------------------------------------------- outputs

def write_context(con, cfg):
    """CONTEXT.md is what every future Claude Code session on this Mac reads first."""
    L = ["# PMP Brain context (auto-generated %s, do not edit; edit config.json or profile.md)" % now().strftime("%Y-%m-%d %H:%M"), ""]
    prof = os.path.join(BASE, "profile.md")
    if os.path.exists(prof):
        with open(prof) as f:
            L += [f.read().strip(), ""]
    L += ["## Projects on this Mac (by category)", ""]
    rows = con.execute("SELECT * FROM projects WHERE active=1 ORDER BY category, last_modified DESC").fetchall()
    cat = None
    for r in rows:
        if r["category"] != cat:
            cat = r["category"]
            L.append("### " + cat)
        state = []
        if r["dirty_files"]:
            state.append("%d uncommitted" % r["dirty_files"])
        if r["unpushed"] and r["unpushed"] > 0:
            state.append("%d unpushed" % r["unpushed"])
        L.append("- `%s` %s%s, last touched %s%s" % (
            r["path"].replace(HOME, "~"), r["kind"],
            (" on " + r["branch"]) if r["branch"] else "",
            (r["last_modified"] or "")[:10],
            (" (" + ", ".join(state) + ")") if state else ""))
    L += ["", "## Recent conversations (last 30 days, newest first)", ""]
    since = (now() - dt.timedelta(days=30)).isoformat()
    for r in con.execute("""SELECT * FROM conversations WHERE ended >= ? ORDER BY ended DESC LIMIT 60""", (since,)):
        L.append("- %s [%s] %s (%s)" % ((r["ended"] or "")[:10], r["category"], r["title"] or "untitled",
                                        (r["project_path"] or "").replace(HOME, "~")))
    L += ["", "## Open alerts", ""]
    for r in con.execute("SELECT * FROM alerts WHERE resolved=0 AND run_date=? ORDER BY level", (today(),)):
        L.append("- %s %s: %s" % (r["level"], r["area"], r["message"]))
    L += ["", "## How to use this", "",
          "- Check here before asking Paul where a project lives, what it's called, or what was decided.",
          "- Query more with `python3 ~/PMPBrain/brain.py search <words>`.",
          "- The database never holds patient details. Keep it that way."]
    with open(CONTEXT, "w") as f:
        f.write("\n".join(L) + "\n")


def write_report(con, alerts, counts):
    os.makedirs(REPORTS, exist_ok=True)
    d = today()
    by = {"ACTION": [], "WATCH": [], "INFO": []}
    for lvl, area, msg in alerts:
        by.setdefault(lvl, []).append("%s: %s" % (area, msg))
    L = ["# Nightly check %s" % d]
    if not by["ACTION"] and not by["WATCH"]:
        L += ["", "Nothing needs you. All checks passed."]
    for lvl, head in (("ACTION", "Needs you"), ("WATCH", "Keep an eye on"), ("INFO", "FYI")):
        if by[lvl]:
            L += ["", "## " + head] + ["- " + x for x in by[lvl]]
    L += ["", "## Numbers",
          "- Projects tracked: %d" % counts["projects"],
          "- New conversations indexed tonight: %d" % counts["new"],
          "- Conversations in the database: %d" % con.execute("SELECT COUNT(*) FROM conversations").fetchone()[0]]
    L += ["", "## Conversations by category (last 7 days)"]
    since = (now() - dt.timedelta(days=7)).isoformat()
    for r in con.execute("SELECT category, COUNT(*) n FROM conversations WHERE ended>=? GROUP BY category ORDER BY n DESC", (since,)):
        L.append("- %s: %d" % (r["category"], r["n"]))
    text = "\n".join(L) + "\n"
    path = os.path.join(REPORTS, d + ".md")
    with open(path, "w") as f:
        f.write(text)
    # phone-readable copy in iCloud Drive (no PHI is ever in this file)
    if os.path.isdir(ICLOUD):
        dst = os.path.join(ICLOUD, "PMPBrain")
        os.makedirs(dst, exist_ok=True)
        shutil.copy(path, os.path.join(dst, "latest-nightly.md"))
    return path


def backup():
    os.makedirs(BACKUPS, exist_ok=True)
    dst = os.path.join(BACKUPS, "brain-%s.db" % today())
    src = sqlite3.connect(DB)
    out = sqlite3.connect(dst)
    src.backup(out)
    out.close()
    src.close()
    keep = sorted(glob.glob(os.path.join(BACKUPS, "brain-*.db")))
    for old in keep[:-14]:
        os.remove(old)


def notify(title, msg):
    if sys.platform != "darwin":
        print("[notify] %s: %s" % (title, msg))
        return
    msg = msg.replace('"', "'")[:230]
    run(["osascript", "-e", 'display notification "%s" with title "%s" sound name "Glass"' % (msg, title)])


# ---------------------------------------------------------------- commands

def cmd_init():
    os.makedirs(BASE, exist_ok=True)
    for name in ("config.json", "profile.md"):
        dst = os.path.join(BASE, name)
        if not os.path.exists(dst):
            shutil.copy(os.path.join(HERE, name), dst)
    connect().close()
    print("PMP Brain ready at", BASE)


def cmd_nightly():
    cfg = load_config()
    con = connect()
    started = now().isoformat()
    cur = con.execute("INSERT INTO runs(started,kind,ok) VALUES(?, 'nightly', 0)", (started,))
    run_id = cur.lastrowid
    con.commit()
    notes = []
    try:
        sync_facts(con, cfg)
        n_proj = sync_projects(con, cfg)
        n_new = sync_conversations(con, cfg)
        con.commit()
        alerts = verify(con, cfg)
        con.execute("UPDATE alerts SET resolved=1 WHERE resolved=0")
        for lvl, area, msg in alerts:
            con.execute("INSERT INTO alerts(run_date,level,area,message) VALUES(?,?,?,?)", (today(), lvl, area, msg))
        con.commit()
        write_context(con, cfg)
        report = write_report(con, alerts, {"projects": n_proj, "new": n_new})
        con.execute("UPDATE runs SET finished=?, ok=1, projects=?, conversations_new=?, alerts=? WHERE id=?",
                    (now().isoformat(), n_proj, n_new, len(alerts), run_id))
        con.commit()
        con.close()
        backup()
        print("Nightly done:", report)
    except Exception as e:
        notes.append(repr(e))
        con.execute("UPDATE runs SET finished=?, ok=0, notes=? WHERE id=?", (now().isoformat(), "; ".join(notes), run_id))
        con.commit()
        notify("PMP Brain: nightly run failed", repr(e))
        raise


def cmd_brief():
    con = connect()
    last = con.execute("SELECT * FROM runs WHERE kind='nightly' ORDER BY id DESC LIMIT 1").fetchone()
    if not last:
        notify("PMP Brain", "No nightly run yet. Run: python3 ~/PMPBrain/brain.py nightly")
        return
    if not last["ok"]:
        notify("PMP Brain", "Last night's check failed: %s" % (last["notes"] or "see ~/PMPBrain/logs"))
        return
    d = last["started"][:10]
    rows = con.execute("SELECT level, area, message FROM alerts WHERE run_date=? AND resolved=0 AND level IN ('ACTION','WATCH') ORDER BY level", (d,)).fetchall()
    if rows:
        top = rows[0]
        msg = "%d item(s). First: %s, %s" % (len(rows), top["area"], top["message"])
    else:
        msg = "All clear. %d projects, %d new conversations indexed." % (last["projects"] or 0, last["conversations_new"] or 0)
    notify("Morning check %s" % d, msg)
    print(msg)


def cmd_status():
    con = connect()
    print("Database:", DB)
    for t in ("projects", "conversations", "facts", "alerts", "runs"):
        print("  %-14s %d" % (t, con.execute("SELECT COUNT(*) FROM %s" % t).fetchone()[0]))
    print("\nProjects by category:")
    for r in con.execute("SELECT category, COUNT(*) n FROM projects WHERE active=1 GROUP BY category ORDER BY n DESC"):
        print("  %-26s %d" % (r["category"], r["n"]))
    print("\nConversations by category:")
    for r in con.execute("SELECT category, COUNT(*) n FROM conversations GROUP BY category ORDER BY n DESC"):
        print("  %-26s %d" % (r["category"], r["n"]))
    last = con.execute("SELECT * FROM runs ORDER BY id DESC LIMIT 1").fetchone()
    if last:
        print("\nLast run: %s  ok=%s  alerts=%s" % (last["started"], last["ok"], last["alerts"]))


def cmd_search(q):
    con = connect()
    like = "%" + q + "%"
    print("Projects:")
    for r in con.execute("SELECT * FROM projects WHERE active=1 AND (name LIKE ? OR path LIKE ? OR category LIKE ? OR last_commit_msg LIKE ?)", (like,) * 4):
        print("  [%s] %s  %s" % (r["category"], r["name"], r["path"]))
    print("Conversations:")
    for r in con.execute("SELECT * FROM conversations WHERE title LIKE ? OR summary LIKE ? OR category LIKE ? OR project_path LIKE ? ORDER BY ended DESC LIMIT 40", (like,) * 4):
        print("  %s [%s] %s  (%s)" % ((r["ended"] or "")[:10], r["category"], r["title"], r["session_id"]))
    print("Facts:")
    for r in con.execute("SELECT * FROM facts WHERE key LIKE ? OR value LIKE ?", (like,) * 2):
        print("  %s: %s" % (r["key"], r["value"]))


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    c = argv[1]
    if c == "init":
        cmd_init()
    elif c == "nightly":
        cmd_nightly()
    elif c == "brief":
        cmd_brief()
    elif c == "status":
        cmd_status()
    elif c == "search" and len(argv) > 2:
        cmd_search(" ".join(argv[2:]))
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
