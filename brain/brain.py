#!/usr/bin/env python3
"""PMP Brain: one local database of Paul's projects and Claude conversations.
It is the memory behind Personal Assistant Katrina (.claude/agents/katrina.md).

Runs on the iMac and the MacBook Pro. Standard library only (works with the
macOS /usr/bin/python3).

  brain.py init          create ~/PMPBrain and the database
  brain.py nightly       scan, cross-reference, verify, write report + CONTEXT.md (launchd, 23:30)
  brain.py brief         morning brief from last night's run (launchd, 06:30)
  brain.py status        print what's in the database
  brain.py search X      search projects, conversations, facts, notes (both Macs)
  brain.py xref [NAME]   what a project or service is connected to; no name = the whole map
  brain.py machines      which Macs have checked in, and when
  brain.py note TOPIC TEXT   keep a decision or fact; it reaches the other Mac
  brain.py sync          swap snapshots with the other Mac now
  brain.py quick         hourly refresh (launchd): git state, new conversations, map, CONTEXT.md
  brain.py open          everything that needs attention on both Macs, in a few lines

Nothing here sends email or posts. It reads local files and writes into
~/PMPBrain, plus a small snapshot (project list, git state, alerts, notes; no
conversation text) in iCloud Drive/PMPBrain/machines so the two Macs see each
other. The only network call is the keepalive ping listed in config.json.
"""

import datetime as dt
import glob
import hashlib
import json
import os
import re
import shutil
import socket
import sqlite3
import subprocess
import urllib.request
import sys

HOME = os.path.expanduser("~")
BASE = os.environ.get("PMP_BRAIN_HOME", os.path.join(HOME, "PMPBrain"))
DB = os.path.join(BASE, "brain.db")
CONFIG = os.path.join(BASE, "config.json")
REPORTS = os.path.join(BASE, "reports")
BACKUPS = os.path.join(BASE, "backups")
CONTEXT = os.path.join(BASE, "CONTEXT.md")
FULL = os.path.join(BASE, "FULL.md")
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
CREATE TABLE IF NOT EXISTS resources (   -- shared services: a domain, a Supabase project, a repo
  id TEXT PRIMARY KEY,
  name TEXT,
  type TEXT,
  category TEXT,
  note TEXT
);
CREATE TABLE IF NOT EXISTS refs (        -- project (path) mentions resource, found in file
  path TEXT,
  resource TEXT,
  file TEXT,
  hits INTEGER,
  PRIMARY KEY (path, resource)
);
CREATE TABLE IF NOT EXISTS links (       -- project/resource -> project/resource
  src TEXT,
  dst TEXT,
  kind TEXT,
  note TEXT,
  PRIMARY KEY (src, dst, kind)
);
CREATE TABLE IF NOT EXISTS peers (       -- the other Mac(s), from their snapshot
  machine TEXT PRIMARY KEY,
  generated TEXT,
  last_run TEXT,
  laptop INTEGER,
  alerts TEXT
);
CREATE TABLE IF NOT EXISTS peer_projects (
  machine TEXT,
  path TEXT,
  name TEXT,
  category TEXT,
  kind TEXT,
  branch TEXT,
  remote TEXT,
  head TEXT,
  dirty_files INTEGER,
  unpushed INTEGER,
  last_modified TEXT,
  uses TEXT,
  PRIMARY KEY (machine, path)
);
CREATE TABLE IF NOT EXISTS notes (
  machine TEXT,
  created TEXT,
  topic TEXT,
  text TEXT,
  PRIMARY KEY (machine, created, text)
);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
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
    if is_laptop():                      # e.g. the MacBook doesn't carry the Work drive
        cfg.update(cfg.get("laptop_overrides", {}))
    cfg["scan_roots"] = [os.path.expanduser(p) for p in cfg.get("scan_roots", [])]
    return cfg


def connect():
    os.makedirs(BASE, exist_ok=True)
    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
    con.executescript(SCHEMA)
    if "head" not in {r[1] for r in con.execute("PRAGMA table_info(projects)")}:
        con.execute("ALTER TABLE projects ADD COLUMN head TEXT")
    return con


def machine_name():
    name = os.environ.get("PMP_BRAIN_MACHINE", "")
    if not name and sys.platform == "darwin":
        name = run(["scutil", "--get", "LocalHostName"])
    name = name or socket.gethostname().split(".")[0] or "mac"
    return re.sub(r"[^A-Za-z0-9_-]", "-", name)[:40]


def is_laptop():
    if "PMP_BRAIN_LAPTOP" in os.environ:
        return os.environ["PMP_BRAIN_LAPTOP"] == "1"
    return sys.platform == "darwin" and "InternalBattery" in run(["pmset", "-g", "batt"])


def shared_dir(cfg):
    """Folder both Macs can see. iCloud Drive unless config.json names another (e.g. a Syncthing folder)."""
    d = cfg.get("shared_dir")
    if d:
        return os.path.expanduser(d)
    return os.path.join(ICLOUD, "PMPBrain") if os.path.isdir(ICLOUD) else None


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
        info["head"] = run(["git", "rev-parse", "--short=12", "HEAD"], path)
        info["last_commit"] = run(["git", "log", "-1", "--format=%cI"], path)
        info["last_commit_msg"] = run(["git", "log", "-1", "--format=%s"], path)[:120]
        text += " " + info["remote"] + " " + run(["git", "log", "-20", "--format=%s"], path)
    else:
        info.update(branch="", remote="", dirty_files=0, unpushed=0, head="",
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
          INSERT INTO projects (path,name,category,kind,branch,remote,head,dirty_files,unpushed,
             last_commit,last_commit_msg,last_modified,has_claude_md,first_seen,last_seen,active)
          VALUES (:path,:name,:category,:kind,:branch,:remote,:head,:dirty_files,:unpushed,
             :last_commit,:last_commit_msg,:last_modified,:has_claude_md,:s,:s,1)
          ON CONFLICT(path) DO UPDATE SET name=excluded.name, category=excluded.category,
             kind=excluded.kind, branch=excluded.branch, remote=excluded.remote,
             head=excluded.head, dirty_files=excluded.dirty_files, unpushed=excluded.unpushed,
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


# ---------------------------------------------------------------- cross-references

TEXT_EXT = {".html", ".htm", ".js", ".mjs", ".ts", ".tsx", ".jsx", ".json", ".md", ".txt", ".py",
            ".sh", ".command", ".toml", ".yml", ".yaml", ".sql", ".css", ".xml", ".plist", ".csv"}
TEXT_NAMES = {"CNAME", "Dockerfile", "Makefile", "Procfile"}
MAX_FILE, MAX_FILES = 400_000, 400


def slug_of(remote):
    """git@github.com:Owner/Repo.git and https://github.com/Owner/Repo -> owner/repo"""
    m = re.search(r"[:/]([\w.-]+/[\w.-]+?)(?:\.git)?/?$", remote or "")
    return m.group(1).lower() if m else ""


def sync_resources(con, cfg):
    """Config resources plus one per git remote on this Mac. Returns [(id, compiled pattern)]."""
    pats = []
    con.execute("DELETE FROM resources")
    for r in cfg.get("resources", []):
        con.execute("INSERT OR REPLACE INTO resources VALUES (?,?,?,?,?)",
                    (r["id"], r.get("name", r["id"]), r.get("type", ""), r.get("category", ""), r.get("note", "")))
        for p in r.get("patterns", []):
            try:
                pats.append((r["id"], re.compile(p, re.I)))
            except re.error:
                pass
    for row in con.execute("SELECT DISTINCT remote FROM projects WHERE active=1 AND remote!=''"):
        slug = slug_of(row["remote"])
        if slug:   # "owner/repo" but not "owner/repo.ca" or "owner/repo-two"
            pats.append(("repo:" + slug, re.compile(re.escape(slug) + r"(?![\w-])(?!\.(?!git\b)\w)", re.I)))
    return pats


def scan_project(path, pats, skip):
    """Count mentions of each resource in a project's text files. Keeps the file name, never the text."""
    hits, seen = {}, 0
    for dp, dn, fn in os.walk(path):
        dn[:] = [d for d in dn if d not in skip and (not d.startswith(".") or d in (".github", ".claude"))]
        for f in fn:
            if f.startswith(".env") or not (os.path.splitext(f)[1].lower() in TEXT_EXT or f in TEXT_NAMES):
                continue
            fp = os.path.join(dp, f)
            try:
                if os.path.getsize(fp) > MAX_FILE:
                    continue
                with open(fp, errors="ignore") as fh:
                    text = fh.read()
            except OSError:
                continue
            for rid, rx in pats:
                n = len(rx.findall(text))
                if n:
                    h = hits.setdefault(rid, [0, os.path.relpath(fp, path)])
                    h[0] += n
            seen += 1
            if seen >= MAX_FILES:
                return hits
    return hits


def sync_refs(con, cfg):
    pats = sync_resources(con, cfg)
    sig = hashlib.md5(repr([(i, p.pattern) for i, p in pats]).encode()).hexdigest()[:12]
    skip = set(cfg.get("skip_dirs", [])) | {".git"}
    quiet = set(cfg.get("xref_skip_projects", []))
    live = set()
    for r in con.execute("SELECT * FROM projects WHERE active=1").fetchall():
        live.add(r["path"])
        # the clinical lane is never read; the brain's own folders mention everything by design
        if r["category"] == "Clinical documentation" or r["name"] in quiet:
            con.execute("DELETE FROM refs WHERE path=?", (r["path"],))
            continue
        key, stamp = "scan:" + r["path"], "%s|%s" % (r["last_modified"], sig)
        old = con.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        if old and old[0] == stamp:
            continue                       # nothing changed since the last scan
        own = "repo:" + slug_of(r["remote"])
        con.execute("DELETE FROM refs WHERE path=?", (r["path"],))
        for rid, (n, f) in scan_project(r["path"], pats, skip).items():
            if rid != own:
                con.execute("INSERT OR REPLACE INTO refs VALUES (?,?,?,?)", (r["path"], rid, f, n))
        con.execute("INSERT OR REPLACE INTO meta VALUES (?,?)", (key, stamp))
    for row in con.execute("SELECT DISTINCT path FROM refs").fetchall():
        if row[0] not in live:
            con.execute("DELETE FROM refs WHERE path=?", (row[0],))

    # links: the ones written down in config.json, then one per repo that names another repo
    con.execute("DELETE FROM links")
    for l in cfg.get("links", []):
        con.execute("INSERT OR REPLACE INTO links VALUES (?,?,?,?)",
                    (l["from"], l["to"], l.get("kind", "linked to"), l.get("note", "")))
    by_slug = {}
    for r in con.execute("SELECT name, remote FROM projects WHERE active=1 AND remote!=''"):
        by_slug.setdefault(slug_of(r["remote"]), r["name"])
    for r in con.execute("""SELECT p.name, f.resource, f.file FROM refs f JOIN projects p ON p.path=f.path
                            WHERE f.resource LIKE 'repo:%'""").fetchall():
        other = by_slug.get(r["resource"][5:])
        if other and other != r["name"]:
            con.execute("INSERT OR IGNORE INTO links VALUES (?,?,?,?)",
                        (r["name"], other, "mentions", "in " + r["file"]))


def resource_users(con):
    """{resource id: sorted project names}, this Mac and the others."""
    out = {}
    for r in con.execute("SELECT p.name, f.resource FROM refs f JOIN projects p ON p.path=f.path WHERE p.active=1"):
        out.setdefault(r["resource"], set()).add(r["name"])
    for r in con.execute("SELECT name, uses FROM peer_projects"):
        for rid in filter(None, (r["uses"] or "").split(",")):
            out.setdefault(rid, set()).add(r["name"])
    return {k: sorted(v) for k, v in out.items()}


def map_lines(con):
    """The whole map, short enough to sit in CONTEXT.md."""
    names = {r["id"]: (r["name"], r["type"]) for r in con.execute("SELECT * FROM resources")}
    L = []
    for rid, users in sorted(resource_users(con).items(), key=lambda kv: (-len(kv[1]), kv[0])):
        if rid in names:
            L.append("- %s (%s): %s" % (names[rid][0], names[rid][1] or "service", ", ".join(users)))
    for r in con.execute("SELECT * FROM links ORDER BY kind='mentions', src, dst"):
        L.append("- %s -> %s: %s%s" % (r["src"], r["dst"], r["kind"], (" (%s)" % r["note"]) if r["note"] else ""))
    return L


# ---------------------------------------------------------------- the other Mac

def export_snapshot(con, cfg):
    """What the other Mac needs to know about this one. No conversation text, no file contents."""
    d = shared_dir(cfg)
    if not d:
        return None
    uses = {}
    for r in con.execute("SELECT path, resource FROM refs"):
        uses.setdefault(r["path"], []).append(r["resource"])
    me = machine_name()
    last = con.execute("SELECT finished FROM runs WHERE kind='nightly' AND ok=1 ORDER BY id DESC LIMIT 1").fetchone()
    snap = {
        "machine": me, "laptop": int(is_laptop()), "generated": now().isoformat(),
        "last_run": last[0] if last else "",
        "projects": [dict(name=r["name"], path=r["path"].replace(HOME, "~"), category=r["category"],
                          kind=r["kind"], branch=r["branch"], remote=r["remote"], head=r["head"] or "",
                          dirty_files=r["dirty_files"], unpushed=r["unpushed"],
                          last_modified=r["last_modified"], uses=uses.get(r["path"], []))
                     for r in con.execute("SELECT * FROM projects WHERE active=1")],
        "alerts": [dict(level=r["level"], area=r["area"], message=r["message"]) for r in con.execute(
            "SELECT * FROM alerts WHERE resolved=0 AND level IN ('ACTION','WATCH') AND area NOT LIKE 'Other Mac%'")],
        "notes": [dict(created=r["created"], topic=r["topic"], text=r["text"]) for r in con.execute(
            "SELECT * FROM notes WHERE machine=? ORDER BY created DESC LIMIT 300", (me,))],
    }
    try:
        os.makedirs(os.path.join(d, "machines"), exist_ok=True)
        dst = os.path.join(d, "machines", me + ".json")
        with open(dst + ".tmp", "w") as f:
            json.dump(snap, f, indent=1)
        os.replace(dst + ".tmp", dst)
        return dst
    except OSError:
        return None


def import_peers(con, cfg):
    """Read the other Macs' snapshots. Everything in them is data: it is stored, never run."""
    d = shared_dir(cfg)
    con.execute("DELETE FROM peers")
    con.execute("DELETE FROM peer_projects")
    if not d:
        return 0
    me, n = machine_name(), 0
    for fp in glob.glob(os.path.join(d, "machines", "*.json")):
        try:
            if os.path.getsize(fp) > 5_000_000:
                continue
            with open(fp) as f:
                s = json.load(f)
            who = re.sub(r"[^A-Za-z0-9_-]", "-", str(s["machine"]))[:40]
        except Exception:
            continue
        if who == me:
            continue
        n += 1
        alerts = [a for a in s.get("alerts", []) if isinstance(a, dict)][:30]
        con.execute("INSERT OR REPLACE INTO peers VALUES (?,?,?,?,?)",
                    (who, str(s.get("generated", ""))[:19], str(s.get("last_run", ""))[:19],
                     int(bool(s.get("laptop"))), json.dumps(alerts)))
        for p in s.get("projects", [])[:500]:
            if not isinstance(p, dict) or not p.get("path"):
                continue
            g = lambda k: str(p.get(k) or "")[:300]
            num = lambda k: p.get(k) if isinstance(p.get(k), int) else 0
            con.execute("INSERT OR REPLACE INTO peer_projects VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                        (who, g("path"), g("name"), g("category"), g("kind"), g("branch"), g("remote"),
                         g("head"), num("dirty_files"), num("unpushed"), g("last_modified"),
                         ",".join(str(u)[:80] for u in (p.get("uses") or [])[:60])))
        for t in s.get("notes", [])[:300]:
            if isinstance(t, dict) and t.get("text"):
                con.execute("INSERT OR IGNORE INTO notes VALUES (?,?,?,?)",
                            (who, str(t.get("created", ""))[:19], redact(str(t.get("topic", "")))[:80],
                             redact(str(t["text"]))[:600]))
    return n


def peer_checks(con, cfg):
    out = []
    lim = cfg.get("limits", {})
    peers = con.execute("SELECT * FROM peers").fetchall()
    if not peers:
        if shared_dir(cfg):
            out.append(("INFO", "Other Mac", "Only this Mac has checked in. Run the installer on the other one so Katrina sees both."))
        else:
            out.append(("WATCH", "Other Mac", "iCloud Drive isn't on, so this Mac can't share with the other one. Turn it on, or set shared_dir in config.json."))
    for p in peers:
        try:
            age = (now() - dt.datetime.fromisoformat(p["generated"])).days
        except ValueError:
            age = 99
        if not p["laptop"]:
            try:
                hours = (now() - dt.datetime.fromisoformat(p["generated"])).total_seconds() / 3600
            except ValueError:
                hours = 999
            if hours >= lim.get("desktop_peer_hours", 3):
                out.append(("ACTION", "Other Mac", "%s (the always-on Mac) last checked in %d hours ago. It may be off, asleep or offline: check power and Wi-Fi." % (p["machine"], hours)))
        elif age >= lim.get("peer_days", 4):
            out.append(("WATCH", "Other Mac", "%s last checked in %d days ago, so what's listed for it is stale. Open it and let it run." % (p["machine"], age)))
    mine = {}
    for r in con.execute("SELECT * FROM projects WHERE active=1 AND remote!=''"):
        mine.setdefault(slug_of(r["remote"]), r)
    for pp in con.execute("SELECT * FROM peer_projects WHERE remote!=''").fetchall():
        r = mine.get(slug_of(pp["remote"]))
        if not r:
            continue
        loose = []
        if pp["dirty_files"]:
            loose.append("%d uncommitted file(s)" % pp["dirty_files"])
        if pp["unpushed"] and pp["unpushed"] > 0:
            loose.append("%d unpushed commit(s)" % pp["unpushed"])
        if loose:
            out.append(("WATCH", r["category"], "%s has %s on %s. Push from there before editing it here, or the two copies split." % (r["name"], " and ".join(loose), pp["machine"])))
        elif (pp["head"] and r["head"] and pp["head"] != r["head"] and pp["branch"] == r["branch"]
              and not r["dirty_files"] and not (r["unpushed"] and r["unpushed"] > 0)):
            out.append(("INFO", r["category"], "%s is on a different commit here than on %s (branch %s). Run git pull on the one that's behind." % (r["name"], pp["machine"], r["branch"])))
    return out


CLAUDE_SHARED = ("agents", "skills", "commands")


def sync_claude_config(cfg):
    """Two-way copy of ~/.claude/{agents,skills,commands} through the shared folder.
    Newest file wins; nothing is ever deleted; credentials and chats are never touched."""
    d = shared_dir(cfg)
    if not d:
        return 0
    n = 0
    for sub in CLAUDE_SHARED:
        local, remote = os.path.join(HOME, ".claude", sub), os.path.join(d, "claude", sub)
        pairs = {}
        for base, side in ((local, "l"), (remote, "r")):
            for dp, dn, fn in os.walk(base):
                dn[:] = [x for x in dn if not x.startswith(".")]
                for f in fn:
                    if f.startswith(".") or f.endswith((".tmp", ".lock")):
                        continue
                    rel = os.path.relpath(os.path.join(dp, f), base)
                    pairs.setdefault(rel, {})[side] = os.path.join(dp, f)
        for rel, p in pairs.items():
            src = dst = None
            if "l" in p and "r" not in p:
                src, dst = p["l"], os.path.join(remote, rel)
            elif "r" in p and "l" not in p:
                src, dst = p["r"], os.path.join(local, rel)
            else:
                ml, mr = os.path.getmtime(p["l"]), os.path.getmtime(p["r"])
                if abs(ml - mr) > 2:
                    src, dst = (p["l"], p["r"]) if ml > mr else (p["r"], p["l"])
            if src:
                try:
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    shutil.copy2(src, dst)
                    n += 1
                except OSError:
                    pass
    return n


# ---------------------------------------------------------------- search index

def build_search(con):
    """Full-text index over everything, both Macs. Rebuilt nightly; a lookup takes milliseconds."""
    try:
        con.execute("CREATE VIRTUAL TABLE IF NOT EXISTS search_idx USING fts5(kind, title, body, ref UNINDEXED, tokenize='porter unicode61')")
    except sqlite3.OperationalError:
        return False                       # no FTS5 in this sqlite: search falls back to LIKE
    con.execute("DELETE FROM search_idx")
    add = lambda *row: con.execute("INSERT INTO search_idx VALUES (?,?,?,?)", row)
    users = resource_users(con)
    for r in con.execute("SELECT * FROM projects WHERE active=1"):
        add("Project", r["name"], " ".join([r["category"] or "", r["branch"] or "", r["remote"] or "",
                                              r["last_commit_msg"] or ""]), r["path"].replace(HOME, "~"))
    for r in con.execute("SELECT * FROM peer_projects"):
        add("Project on " + r["machine"], r["name"], " ".join([r["category"], r["branch"], r["remote"]]), r["path"])
    for r in con.execute("SELECT * FROM conversations"):
        add("Conversation", r["title"] or "untitled", " ".join([r["category"] or "", r["summary"] or "",
                                                                  r["project_path"] or ""]),
            "%s %s" % ((r["ended"] or "")[:10], r["session_id"]))
    for r in con.execute("SELECT * FROM facts"):
        add("Fact", r["key"], r["value"], r["category"])
    for r in con.execute("SELECT * FROM resources"):
        add("Service", r["name"], " ".join([r["id"], r["type"], r["note"], " ".join(users.get(r["id"], []))]),
            "used by " + (", ".join(users.get(r["id"], [])) or "nothing scanned yet"))
    for r in con.execute("SELECT * FROM links"):
        add("Link", "%s -> %s" % (r["src"], r["dst"]), r["kind"] + " " + r["note"], r["kind"])
    for r in con.execute("SELECT * FROM notes"):
        add("Note", r["topic"], r["text"], "%s on %s" % (r["created"][:10], r["machine"]))
    return True


# ---------------------------------------------------------------- verification

def token_checks(con, cfg):
    """Daily, free (no AI call): things that make every Claude session slower and costlier."""
    out = []
    lim = cfg.get("limits", {})
    big = lim.get("instructions_kb", 8) * 1024
    # instruction files load into every session: keep them short
    files = [os.path.join(HOME, ".claude", "CLAUDE.md")]
    files += [os.path.join(r["path"], "CLAUDE.md") for r in con.execute("SELECT path FROM projects WHERE active=1 AND has_claude_md=1")]
    for f in files:
        try:
            size = os.path.getsize(f)
        except OSError:
            continue
        if size > big:
            out.append(("WATCH", "Token use", "%s is %d KB and loads into every session there. Trim it under %d KB or move detail into files read on demand."
                        % (f.replace(HOME, "~"), size // 1024, big // 1024)))
    try:
        size = os.path.getsize(CONTEXT)
        if size > cfg.get("limits", {}).get("context_chars", 6000) * 1.2:
            out.append(("WATCH", "Token use", "CONTEXT.md is %d KB, over its budget. Lower limits.context_chars or trim profile.md." % (size // 1024)))
    except OSError:
        pass
    # very long conversations re-send their whole history every turn
    since = (now() - dt.timedelta(days=7)).isoformat()
    long_n = lim.get("long_session_messages", 150)
    rows = con.execute("SELECT title, messages FROM conversations WHERE ended >= ? AND messages > ? ORDER BY messages DESC",
                       (since, long_n)).fetchall()
    if rows:
        out.append(("INFO", "Token use", "%d Claude Code chat(s) this week ran past %d messages (longest: %d, \"%s\"). Start a new chat per topic, or /clear, to cut cost."
                    % (len(rows), long_n, rows[0]["messages"], (rows[0]["title"] or "untitled")[:60])))
    return out


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

    # keep free-tier services awake and check they answer (Supabase pauses after ~7 idle days)
    for k in cfg.get("keepalive", []):
        try:
            req = urllib.request.Request(k["url"], headers=k.get("headers", {}))
            code = urllib.request.urlopen(req, timeout=20).status
        except urllib.error.HTTPError as e:
            code = e.code
        except Exception:
            code = 0
        if code == 0 or code >= 500 or code in (402, 503, 540):
            out.append(("ACTION", k.get("category", "Portal & tech"), "%s didn't answer (HTTP %s). It may be paused: restore it in the dashboard." % (k["name"], code or "no reply")))

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

    out += peer_checks(con, cfg)
    out += token_checks(con, cfg)

    # PHI wall check on the database itself
    leaks = 0
    for r in con.execute("SELECT summary, title FROM conversations"):
        blob = (r["summary"] or "") + " " + (r["title"] or "")
        if any(p.search(blob) for p in PHI_PATTERNS[:3]):
            leaks += 1
    for r in con.execute("SELECT rowid, topic, text FROM notes").fetchall():
        if any(p.search(r["topic"] + " " + r["text"]) for p in PHI_PATTERNS[:3]):
            con.execute("DELETE FROM notes WHERE rowid=?", (r["rowid"],))
            leaks += 1
    if leaks:
        con.execute("UPDATE conversations SET summary='' WHERE phi_risk=1")
        out.append(("ACTION", "PHI wall", "%d stored conversation line(s) matched an ID/date pattern. Clinical summaries were wiped; check `brain.py search redacted`." % leaks))

    return out


# ---------------------------------------------------------------- outputs

def write_full(con, cfg):
    """FULL.md is the long version: every path, both Macs, 60 conversations. Read on demand, never auto-loaded."""
    L = ["# PMP Brain, full listing for %s (auto-generated %s, do not edit; edit config.json or profile.md)"
         % (machine_name(), now().strftime("%Y-%m-%d %H:%M")), ""]
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
    L += ["", "## How the projects connect", "",
          "Each line is one shared piece and every project that touches it. Change the piece and you change them all."]
    L += map_lines(con) or ["- Nothing cross-referenced yet."]
    for p in con.execute("SELECT * FROM peers ORDER BY machine"):
        L += ["", "## Also on %s (checked in %s)" % (p["machine"], p["generated"][:16].replace("T", " ")), ""]
        for r in con.execute("SELECT * FROM peer_projects WHERE machine=? ORDER BY category, name", (p["machine"],)):
            state = []
            if r["dirty_files"]:
                state.append("%d uncommitted" % r["dirty_files"])
            if r["unpushed"] and r["unpushed"] > 0:
                state.append("%d unpushed" % r["unpushed"])
            L.append("- [%s] `%s` %s%s%s" % (r["category"], r["path"], r["kind"],
                                             (" on " + r["branch"]) if r["branch"] else "",
                                             (" (" + ", ".join(state) + ")") if state else ""))
        for a in json.loads(p["alerts"] or "[]"):
            L.append("- %s there: %s" % (str(a.get("level", ""))[:6], redact(str(a.get("message", "")))[:240]))
    notes = con.execute("SELECT * FROM notes ORDER BY created DESC LIMIT 25").fetchall()
    if notes:
        L += ["", "## Decisions and notes (newest first, both Macs)", ""]
        L += ["- %s [%s] %s" % (n["created"][:10], n["topic"], n["text"]) for n in notes]
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
          "- Before changing anything shared, run `python3 ~/PMPBrain/brain.py xref <name>` and check each project it lists.",
          "- Keep a decision with `python3 ~/PMPBrain/brain.py note <topic> <text>`. It reaches the other Mac.",
          "- The database never holds patient details. Keep it that way."]
    with open(FULL, "w") as f:
        f.write("\n".join(L) + "\n")


def write_context(con, cfg):
    """CONTEXT.md is loaded into every Claude Code session on this Mac, so every line costs tokens
    in every session. It holds only what changes an answer: rules, what's open, the map, and how to
    look up the rest. Paths, the other Mac's full list and old conversations live in FULL.md and
    the database."""
    budget = cfg.get("limits", {}).get("context_chars", 6000)
    head = ["# PMP Brain context for %s (auto-generated %s; edit profile.md or config.json, not this)"
            % (machine_name(), now().strftime("%Y-%m-%d %H:%M")), ""]
    prof = os.path.join(BASE, "profile.md")
    if os.path.exists(prof):
        with open(prof) as f:
            head += [f.read().strip(), ""]

    opened = ["## Open now", ""]
    for r in con.execute("SELECT * FROM alerts WHERE resolved=0 AND level IN ('ACTION','WATCH') ORDER BY level"):
        opened.append("- %s %s: %s" % (r["level"], r["area"], r["message"]))
    for p in con.execute("SELECT * FROM peers ORDER BY machine"):
        for a in json.loads(p["alerts"] or "[]"):
            opened.append("- %s on %s: %s" % (str(a.get("level", ""))[:6], p["machine"], redact(str(a.get("message", "")))[:200]))
    if len(opened) == 2:
        opened.append("- Nothing. Last night's check was clean.")

    proj = ["", "## Projects (name only; `xref <name>` gives path, branch, state and ties)", ""]
    cats = {}
    for r in con.execute("SELECT name, category, dirty_files, unpushed FROM projects WHERE active=1 ORDER BY category, name"):
        loose = r["dirty_files"] or (r["unpushed"] and r["unpushed"] > 0)
        cats.setdefault(r["category"], []).append(r["name"] + ("*" if loose else ""))
    here = {n.rstrip("*") for v in cats.values() for n in v}
    for r in con.execute("SELECT machine, name, category, dirty_files, unpushed FROM peer_projects ORDER BY name"):
        loose = r["dirty_files"] or (r["unpushed"] and r["unpushed"] > 0)
        if r["name"] not in here or loose:
            cats.setdefault(r["category"], []).append("%s%s (%s)" % (r["name"], "*" if loose else "", r["machine"]))
    proj += ["- %s: %s" % (c, ", ".join(v)) for c, v in sorted(cats.items())]
    proj.append("`*` = uncommitted or unpushed work. A name with a Mac in brackets is on the other Mac.")

    users = resource_users(con)
    names = {r["id"]: r["name"] for r in con.execute("SELECT * FROM resources")}
    links = ["", "## How the projects connect (shared pieces only)", ""]
    for rid, us in sorted(users.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        if rid in names and len(us) > 1:
            links.append("- %s: %s" % (names[rid], ", ".join(us)))
    for r in con.execute("SELECT * FROM links WHERE kind!='mentions' ORDER BY src, dst"):
        links.append("- %s -> %s: %s" % (r["src"], r["dst"], r["kind"]))

    recent = []
    notes = con.execute("SELECT * FROM notes ORDER BY created DESC LIMIT 8").fetchall()
    if notes:
        recent += ["", "## Latest decisions", ""] + ["- %s [%s] %s" % (n["created"][:10], n["topic"], n["text"][:160]) for n in notes]
    convs = con.execute("SELECT * FROM conversations ORDER BY ended DESC LIMIT 6").fetchall()
    if convs:
        recent += ["", "## Latest conversations", ""] + ["- %s [%s] %s" % ((c["ended"] or "")[:10], c["category"], (c["title"] or "untitled")[:80]) for c in convs]

    tail = ["", "## Look it up, don't guess and don't re-read files (each is one short command)", "",
            "- `python3 ~/PMPBrain/brain.py xref <name>`: one project or service, everything tied to it. Run before changing anything shared.",
            "- `python3 ~/PMPBrain/brain.py search <words>`: projects, conversations, facts, notes, both Macs.",
            "- `python3 ~/PMPBrain/brain.py open`: everything open right now, both Macs.",
            "- `python3 ~/PMPBrain/brain.py note <topic> <text>`: keep a decision so no session has to work it out again.",
            "- `~/PMPBrain/FULL.md`: every path and 60 conversations. `~/PMPBrain/registry.md`: the cloud side. Read only when needed.",
            "- The database never holds patient details. Keep it that way."]
    # stay inside the budget: drop the least useful block first, never the rules or what's open
    blocks = [head, opened, proj, links, recent, tail]
    for drop in (4, 3):
        if sum(len(l) + 1 for b in blocks for l in b) <= budget:
            break
        blocks[drop] = ["", "(%s left out to keep this short; see FULL.md)" % ("recent items" if drop == 4 else "the map")]
    with open(CONTEXT, "w") as f:
        f.write("\n".join(l for b in blocks for l in b) + "\n")
    write_full(con, cfg)


def write_report(con, alerts, counts):
    os.makedirs(REPORTS, exist_ok=True)
    d = today()
    by = {"ACTION": [], "WATCH": [], "INFO": []}
    for lvl, area, msg in alerts:
        by.setdefault(lvl, []).append("%s: %s" % (area, msg))
    L = ["# Nightly check %s on %s" % (d, machine_name())]
    if not by["ACTION"] and not by["WATCH"]:
        L += ["", "Nothing needs you. All checks passed."]
    for lvl, head in (("ACTION", "Needs you"), ("WATCH", "Keep an eye on"), ("INFO", "FYI")):
        if by[lvl]:
            L += ["", "## " + head] + ["- " + x for x in by[lvl]]
    L += ["", "## Numbers",
          "- Projects tracked: %d" % counts["projects"],
          "- New conversations indexed tonight: %d" % counts["new"],
          "- Conversations in the database: %d" % con.execute("SELECT COUNT(*) FROM conversations").fetchone()[0]]
    for p in con.execute("SELECT * FROM peers ORDER BY machine"):
        L += ["", "## %s (checked in %s)" % (p["machine"], p["generated"][:16].replace("T", " "))]
        theirs = json.loads(p["alerts"] or "[]")
        L += ["- %s: %s" % (str(a.get("area", ""))[:40], redact(str(a.get("message", "")))[:240]) for a in theirs] or ["- Nothing open there."]
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


def backup(cfg=None):
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
    # one copy off this Mac, in iCloud Drive (or shared_dir), replaced nightly. No patient data is ever in it.
    d = shared_dir(cfg or load_config())
    if d:
        try:
            os.makedirs(os.path.join(d, "backups"), exist_ok=True)
            shutil.copy2(dst, os.path.join(d, "backups", machine_name() + "-brain.db"))
        except OSError:
            pass


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
        sync_refs(con, cfg)
        import_peers(con, cfg)
        con.commit()
        alerts = verify(con, cfg)
        con.execute("UPDATE alerts SET resolved=1 WHERE resolved=0")
        for lvl, area, msg in alerts:
            con.execute("INSERT INTO alerts(run_date,level,area,message) VALUES(?,?,?,?)", (today(), lvl, area, msg))
        con.commit()
        export_snapshot(con, cfg)
        sync_claude_config(cfg)
        build_search(con)
        con.commit()
        write_context(con, cfg)
        report = write_report(con, alerts, {"projects": n_proj, "new": n_new})
        con.execute("UPDATE runs SET finished=?, ok=1, projects=?, conversations_new=?, alerts=? WHERE id=?",
                    (now().isoformat(), n_proj, n_new, len(alerts), run_id))
        con.commit()
        con.close()
        backup(cfg)
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
    for t in ("projects", "conversations", "facts", "resources", "links", "notes", "peer_projects", "alerts", "runs"):
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
    terms = re.findall(r"\w+", q)
    try:
        rows = con.execute("SELECT kind, title, ref FROM search_idx WHERE search_idx MATCH ? ORDER BY rank LIMIT 60",
                           (" ".join('"%s"*' % t for t in terms),)).fetchall() if terms else []
    except sqlite3.OperationalError:
        rows = None                        # index not built yet (or no FTS5): plain scan
    if rows is not None:
        for r in rows:
            print("  %-14s %s  (%s)" % (r["kind"], r["title"], r["ref"]))
        if not rows:
            print("Nothing matches '%s'." % q)
        return
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


def cmd_xref(q):
    con = connect()
    if not q:
        print("\n".join(map_lines(con)) or "Nothing cross-referenced yet. Run: brain.py nightly")
        return
    like = "%" + q + "%"
    users = resource_users(con)
    res = con.execute("SELECT * FROM resources WHERE lower(id)=lower(?) OR lower(name)=lower(?)", (q, q)).fetchall() \
        or con.execute("SELECT * FROM resources WHERE id LIKE ? OR name LIKE ?", (like, like)).fetchall()
    names = [r[0] for r in con.execute("""SELECT name FROM projects WHERE active=1 AND lower(name)=lower(?)
                                          UNION SELECT name FROM peer_projects WHERE lower(name)=lower(?)""", (q, q))] \
        or [r[0] for r in con.execute("""SELECT name FROM projects WHERE active=1 AND name LIKE ?
                                         UNION SELECT name FROM peer_projects WHERE name LIKE ?""", (like, like))]
    if not res and not names:
        print("Nothing called '%s'. Try: brain.py search %s" % (q, q))
        return
    label = {r["id"]: r["name"] for r in con.execute("SELECT * FROM resources")}
    for name in names:
        print("PROJECT %s" % name)
        for r in con.execute("SELECT * FROM projects WHERE active=1 AND name=?", (name,)):
            print("  here (%s): %s  %s %s, %d uncommitted, %s unpushed" % (
                machine_name(), r["path"].replace(HOME, "~"), r["kind"], r["branch"] or "", r["dirty_files"] or 0, r["unpushed"] or 0))
            since = (now() - dt.timedelta(days=30)).isoformat()
            convs = con.execute("SELECT * FROM conversations WHERE project_path LIKE ? AND ended>=? ORDER BY ended DESC",
                                (r["path"] + "%", since)).fetchall()
            if convs:
                print("  conversations, last 30 days: %d. Latest: %s" % (len(convs), "; ".join(
                    "%s %s" % ((c["ended"] or "")[:10], c["title"] or "untitled") for c in convs[:4])))
        for r in con.execute("SELECT * FROM peer_projects WHERE name=?", (name,)):
            print("  on %s: %s  %s %s, %d uncommitted, %s unpushed" % (
                r["machine"], r["path"], r["kind"], r["branch"], r["dirty_files"] or 0, r["unpushed"] or 0))
        mine = sorted(rid for rid, us in users.items() if name in us and rid in label)
        for rid in mine:
            others = [u for u in users[rid] if u != name]
            ev = con.execute("SELECT f.file FROM refs f JOIN projects p ON p.path=f.path WHERE p.name=? AND f.resource=?", (name, rid)).fetchone()
            print("  uses %s%s%s" % (label[rid], (" [%s]" % ev[0]) if ev else "",
                                     (". Also used by: " + ", ".join(others)) if others else ""))
        for r in con.execute("SELECT * FROM links WHERE src=? OR dst=?", (name, name)):
            print("  %s -> %s: %s%s" % (r["src"], r["dst"], r["kind"], (" (%s)" % r["note"]) if r["note"] else ""))
        for n in con.execute("SELECT * FROM notes WHERE lower(topic)=lower(?) ORDER BY created DESC LIMIT 8", (name,)):
            print("  note %s: %s" % (n["created"][:10], n["text"]))
    for r in res:
        print("SERVICE %s (%s)%s" % (r["name"], r["type"] or r["id"], (": " + r["note"]) if r["note"] else ""))
        print("  used by: %s" % (", ".join(users.get(r["id"], [])) or "no project scanned on either Mac"))
        for l in con.execute("SELECT * FROM links WHERE src IN (?,?) OR dst IN (?,?)", (r["id"], r["name"]) * 2):
            print("  %s -> %s: %s%s" % (l["src"], l["dst"], l["kind"], (" (%s)" % l["note"]) if l["note"] else ""))


def cmd_machines():
    cfg = load_config()
    con = connect()
    last = con.execute("SELECT finished FROM runs WHERE kind='nightly' AND ok=1 ORDER BY id DESC LIMIT 1").fetchone()
    print("%-22s this Mac%s, last good run %s" % (machine_name(), " (laptop)" if is_laptop() else "", last[0] if last else "never"))
    for p in con.execute("SELECT * FROM peers ORDER BY machine"):
        n = con.execute("SELECT COUNT(*) FROM peer_projects WHERE machine=?", (p["machine"],)).fetchone()[0]
        print("%-22s checked in %s, %d projects, %d open alert(s)" % (p["machine"], p["generated"], n, len(json.loads(p["alerts"] or "[]"))))
    print("Shared folder:", shared_dir(cfg) or "none (iCloud Drive is off)")


def cmd_quick():
    """Hourly refresh: git state, new conversations, cross-references, the other Mac, search, CONTEXT.md.
    No health checks, no report, no backup. Unchanged projects are skipped, so it takes about a second."""
    cfg = load_config()
    con = connect()
    sync_facts(con, cfg)
    n = sync_projects(con, cfg)
    new = sync_conversations(con, cfg)
    sync_refs(con, cfg)
    import_peers(con, cfg)
    export_snapshot(con, cfg)
    synced = sync_claude_config(cfg)
    build_search(con)
    con.execute("INSERT OR REPLACE INTO meta VALUES ('quick', ?)", (now().isoformat(),))
    con.commit()
    write_context(con, cfg)
    print("Quick update: %d projects, %d new conversation(s), %d Claude config file(s) synced." % (n, new, synced))


def cmd_open():
    """Everything that needs attention, in as few lines as possible."""
    con = connect()
    rows = ["%s %s: %s" % (r["level"], r["area"], r["message"]) for r in con.execute(
        "SELECT * FROM alerts WHERE resolved=0 AND level IN ('ACTION','WATCH') ORDER BY level")]
    for r in con.execute("SELECT * FROM projects WHERE active=1 AND kind='git' AND (dirty_files>0 OR unpushed>0)"):
        rows.append("LOOSE %s: %d uncommitted, %d unpushed (%s)" % (r["name"], r["dirty_files"] or 0, max(r["unpushed"] or 0, 0), r["path"].replace(HOME, "~")))
    for p in con.execute("SELECT * FROM peers ORDER BY machine"):
        for a in json.loads(p["alerts"] or "[]"):
            rows.append("%s on %s: %s" % (str(a.get("level", ""))[:6], p["machine"], redact(str(a.get("message", "")))[:200]))
        for r in con.execute("SELECT * FROM peer_projects WHERE machine=? AND (dirty_files>0 OR unpushed>0)", (p["machine"],)):
            rows.append("LOOSE on %s, %s: %d uncommitted, %d unpushed" % (p["machine"], r["name"], r["dirty_files"] or 0, max(r["unpushed"] or 0, 0)))
    q = con.execute("SELECT value FROM meta WHERE key='quick'").fetchone()
    print("\n".join(rows) if rows else "Nothing open on either Mac.")
    print("(as of %s)" % (q[0] if q else "last nightly run"))


def cmd_sync():
    cfg = load_config()
    con = connect()
    n = import_peers(con, cfg)
    dst = export_snapshot(con, cfg)
    build_search(con)
    con.commit()
    write_context(con, cfg)
    print("Read %d other Mac(s). Wrote %s" % (n, dst or "nothing: no shared folder"))


def cmd_note(topic, text):
    blob = topic + " " + text
    if len(CLINICAL_WORDS.findall(blob)) >= 3 or any(p.search(blob) for p in PHI_PATTERNS[:3]):
        print("Not kept: that reads like patient detail. Notes are for project decisions only.")
        return 1
    con = connect()
    con.execute("INSERT OR IGNORE INTO notes VALUES (?,?,?,?)",
                (machine_name(), now().isoformat(), redact(topic)[:80], redact(" ".join(text.split()))[:600]))
    con.commit()
    con.close()
    cmd_sync()
    return 0


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
    elif c == "xref":
        cmd_xref(" ".join(argv[2:]))
    elif c == "quick":
        cmd_quick()
    elif c == "open":
        cmd_open()
    elif c == "machines":
        cmd_machines()
    elif c == "sync":
        cmd_sync()
    elif c == "note" and len(argv) > 3:
        return cmd_note(argv[2], " ".join(argv[3:]))
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
