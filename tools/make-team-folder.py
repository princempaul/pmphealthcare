#!/usr/bin/env python3
"""Build ~/Desktop/BWMCS/Files For Team and sort COPIES of clinic files into it.

  python3 make-team-folder.py          preview only: shows where every file would go
  python3 make-team-folder.py --go     builds the folder and copies the files

Your original files are never moved, renamed or deleted. Run it again any time: files already
copied are skipped, so only new ones are added.

Patient privacy: a file is NOT copied if it is in a patient folder, is a personal ID (driver's
licence, passport), or has a patient name, date of birth or health card number inside it.
Logins (recovery codes, passwords, company keys) are never copied. Everything else is. It is listed in
"BWMCS/Held back for privacy review - PAUL ONLY.txt" (outside the team folder) so you can decide by hand.
"""
import os, re, shutil, sys, datetime

HOME = os.path.expanduser("~")
DEST = os.path.join(HOME, "Desktop", "BWMCS", "Files For Team")
SOURCES = [os.path.join(HOME, "Desktop", "BWMCS"), os.path.join(HOME, "Desktop", "BWMWC"),
           "/Volumes/Work/clinic"]
SOURCES += [p for p in sys.argv[1:] if not p.startswith("--")]   # extra folders to sort

TREE = {
    "00 Start Here": [],
    "01 Policies & Procedures": [],
    "02 Clinical Guidelines & References": [],
    "03 Treatment Plans & Care Pathways": [],
    "04 Forms & Templates": ["Intake & Consent", "Assessments & Screening Tools", "Occupational Health",
                             "Referrals & Requisitions", "Billing & Administration", "Other Forms"],
    "05 Patient Education & Brochures": [],
    "06 Social Media & Reels": ["Reels & Videos", "Posts & Ads"],
    "07 Staff Onboarding & Training": [],
    "08 Clinic Operations": [],
    "99 To Sort": [],
}

# This folder is for staff review, training and resources. These never go in (not copied, not listed):
# brand files, stock and raw images, mockups, build and dev files, corporate/legal/money papers,
# prescription pads and stamps, superseded versions.
NOT_FOR_TEAM = re.compile(
    r"logo|letterhead|business ?card|^card |clinic ?card|^front |^back[ .]|email ?signature|mark only|brand|style ?guide|"
    r"door ?sign|wall ?sign|plaque|signage|mounting ?template|3d ?(edition|print)|cover ?photo|cover v|_cover|cover \d|"
    r"profile ?square|avatar|favicon|touch ?icon|^icon|maskable|np ?stamp|\\bseal\\b|prescription ?pad|rx ?pad|^bluewater rx |"
    r"unsplash|pexels|photo ?credits|mockup|render|realistic|3d ?views|^real |preview ?sheet|equirectangular|"
    r"screenshot|test ?frame|^test[ .]|draft ?footage|b ?roll|\\braw\\b|"
    r"claude|kickoff|skill\.md|readme|robots|spell ?words|server ?settings|website ?status|index\.csv|"
    r"listing ?copy|migration ?map|admin ?urls|email ?setup|register\.backup|"
    r"superseded|incorporat|by ?law|decision ?record|articles|certificate of|lease|contractor ?agreement|"
    r"insurance ?doc|invoice|huntington|chief complaint|purchase ?list",
    re.I)
KEEP_TEXT = re.compile(r"reels? captions", re.I)      # text files that are finished content
POST_IMAGE = re.compile(r"post|flyer|poster|carousel|story|infographic|\bad\b|tear ?off", re.I)

# Order matters: the first rule that matches wins.
RULES = [
    (r"^(00 )?(master index|read ?me folder|clinical package master index|folder guide)", "00 Start Here"),
    (r"jane build|staff|role guide|onboarding|orientation|training|competenc|job ?description", "07 Staff Onboarding & Training"),
    (r"^sg\d\d|practice manual|psychotherapy program|guideline|age friendly", "02 Clinical Guidelines & References"),
    (r"^(\d\d )?(m|n|p|o|s|h|f|fut)\d\dr? ", "03 Treatment Plans & Care Pathways"),
    (r"whmis|workplace violence|health and safety|first aid|policy|procedure|ipac", "01 Policies & Procedures"),
    (r"meeting|document register|supplies|supply|inventory|fridge|temperature log", "08 Clinic Operations"),
    (r"reels? captions", "06 Social Media & Reels/Posts & Ads"),
    (r"flyer|poster|post |carousel|\bad\b", "06 Social Media & Reels/Posts & Ads"),
    (r"^(\d\d )?(c|t)\d\d ", "04 Forms & Templates/Intake & Consent"),
    (r"forms package|all forms|fillable|incident|follow up visit", "04 Forms & Templates/Other Forms"),
    (r"\b(logo|brand|colou?r ?palette|letterhead|business ?card|style ?guide)\b", "06 Social Media & Reels/Posts & Ads"),
    (r"\b(flyer|poster|advert|ads?|banner|campaign|billboard|postcard|promo)\b", "06 Social Media & Reels/Posts & Ads"),
    (r"\b(reel|instagram|facebook|tiktok|youtube|linkedin|social|story|caption|thumbnail)\b", "06 Social Media & Reels/Posts & Ads"),
    (r"\b(brochure|pamphlet|handout|leaflet|info ?sheet|fact ?sheet|patient ?education|what to expect|aftercare|instructions)\b", "05 Patient Education & Brochures"),
    (r"\b(treatment ?plan|care ?plan|care ?pathway|pathway|order ?set|plan ?builder|management ?plan)\b", "03 Treatment Plans & Care Pathways"),
    (r"\b(guideline|cpg|reference|algorithm|monograph|evidence|best ?practice|bpg|standards?)\b", "02 Clinical Guidelines & References"),
    (r"\b(policy|policies|procedure|sop|ipac|infection|sterili[sz]|privacy|phipa|confidential|emergency ?plan|code)\b", "01 Policies & Procedures"),
    (r"\b(onboarding|orientation|training|competenc|education ?day|in-?service|job ?description|staff ?checklist)\b", "07 Staff Onboarding & Training"),
    (r"\b(consent|intake|registration|new ?patient|demographic|release of information)\b", "04 Forms & Templates/Intake & Consent"),
    (r"\b(assessment|screening|questionnaire|asrs|phq|gad|audit-?c|epworth|stop-?bang|scale|tool)\b", "04 Forms & Templates/Assessments & Screening Tools"),
    (r"\b(fit ?test|n95|tb|tuberculin|pre-?employment|driver|medical ?exam|occupational|drug ?screen|audiogram|spirometry)\b", "04 Forms & Templates/Occupational Health"),
    (r"\b(referral|requisition|lab ?req|imaging)\b", "04 Forms & Templates/Referrals & Requisitions"),
    (r"\b(invoice|receipt|fee|price|billing|insurance|claim|payment)\b", "04 Forms & Templates/Billing & Administration"),
    (r"\b(schedule|roster|contact ?list|phone ?list|equipment|inventory|supplies|maintenance|cleaning ?log|temperature ?log|fridge)\b", "08 Clinic Operations"),
    (r"\b(form|template|checklist)\b", "04 Forms & Templates/Other Forms"),
]
VIDEO = {".mp4", ".mov", ".m4v", ".avi"}
IMAGE = {".jpg", ".jpeg", ".png", ".heic", ".gif", ".webp", ".svg"}
DOCS = {".pdf", ".doc", ".docx", ".pages", ".rtf", ".txt", ".md", ".odt", ".xls", ".xlsx", ".numbers",
        ".csv", ".ppt", ".pptx", ".key"} | VIDEO | IMAGE | {".ai", ".psd", ".indd", ".eps"}

# What stays out of the team folder: patient identifiers, logins, and personal ID. Everything else goes in.
# Logins and keys: never copied, never listed.
CREDENTIAL = re.compile(r"recovery|pass ?word|passcode|company ?key|credential|authenticat|\b2fa\b|api ?key|secret ?key", re.I)
# Personal ID documents (carry DOB and ID numbers): held for Paul.
PERSONAL_ID = re.compile(r"(^|[ _\-/(])dls?([ ._)]|$)|driver.?s? ?licen[cs]e|passport|health ?card|ohip ?card|sin ?card", re.I)
# File names that only a patient record has: held.
PATIENT_NAME = re.compile(r"\b(chart|charts|progress ?note|soap ?note|visit ?note|encounter ?note|discharge ?summary|"
                          r"this writer|admission of|lab ?results?|bloodwork)\b", re.I)
# Any file inside a folder with one of these names is treated as a patient record.
PRIVATE_DIR = re.compile(r"^(patients?|patient ?files?.*|patient ?notes?|patient ?records?|clients?|charts?|records?|"
                         r"residents?|medical records|emr|scans?|tb test reports?|dls of .*|.*partner.?id.*)$")
# Identifiers inside a file.
ID_IN_TEXT = [
    ("health card number", re.compile(r"(?<![\d-])\d{4}[- ]\d{3}[- ]\d{3}(?:[- ]?[A-Z]{2})?(?![\d-])")),
    ("date of birth", re.compile(r"(date of birth|d\.?o\.?b\.?|birth ?date)\s*[:\-]?\s*(\d{1,4}[/\-. ]\d{1,2}[/\-. ]\d{1,4}|[A-Z][a-z]{2,8}\.? \d{1,2},? \d{4})", re.I)),
    ("patient name", re.compile(r"(patient|client|resident)('s)? (full )?name\s*[:\-]\s*[A-Z][a-z]+ [A-Z][a-z]+")),
    ("SIN", re.compile(r"\b(SIN|social insurance)\b[^\n]{0,20}\d{3}[- ]?\d{3}[- ]?\d{3}", re.I)),
]
ID_FIELD = re.compile(r"name|dob|birth|health ?card|hcn|ohip|address|phone|email|sin\b", re.I)
try:
    import pypdf, logging, warnings
    logging.getLogger("pypdf").setLevel(logging.CRITICAL)
    warnings.filterwarnings("ignore")
except Exception:
    pypdf = None


def identifiers(path):
    """Return why a file looks like it holds patient identifiers, or None."""
    ext = os.path.splitext(path)[1].lower()
    text = ""
    try:
        if ext == ".pdf":
            if pypdf is None:
                return None
            r = pypdf.PdfReader(path)
            if r.is_encrypted:
                return "locked PDF, can't check"
            text = "\n".join((pg.extract_text() or "") for pg in r.pages[:40])
            for k, v in (r.get_fields() or {}).items():
                val = v.get("/V")
                if val not in (None, "", "/Off", "Off") and ID_FIELD.search(k) and not re.search(r"clinic|custodian|privacy|after.hours|provider|np_|prescriber", k, re.I):
                    return "filled-in form (%s)" % k[:30]
        elif ext in (".docx", ".doc", ".rtf", ".odt", ".pages"):
            import subprocess
            text = subprocess.run(["textutil", "-convert", "txt", "-stdout", path], capture_output=True, text=True, timeout=60).stdout
        elif ext in (".txt", ".md", ".csv"):
            text = open(path, errors="ignore").read()
    except Exception:
        return "can't read, check by hand" if ext == ".pdf" else None
    for label, rx in ID_IN_TEXT:
        if rx.search(text):
            return label
    return None


SKIP_DIRS = {"Files For Team", ".git", "node_modules", "Library", ".Trash", "PMPBrain",
             "Jane Recovery Code Authenticator", "_backup_pre-206_2026-10-20", "Website"}


def classify(path):
    rel = path.lower().replace("_", " ").replace("-", " ")
    name = os.path.basename(rel)
    ext = os.path.splitext(name)[1]
    if ext in VIDEO:
        return "06 Social Media & Reels/Reels & Videos"
    for rx, folder in RULES:
        if re.search(rx, name):
            return folder
    for rx, folder in RULES:                    # fall back to the folder names around the file
        if re.search(rx, os.path.dirname(rel)):
            return folder
    if ext in IMAGE and re.search(r"advert|market|reel|social|promo", rel):
        return "06 Social Media & Reels/Posts & Ads"
    return "99 To Sort"


def human(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return "%.1f %s" % (n, unit) if unit != "B" else "%d B" % n
        n /= 1024.0


def main():
    go = "--go" in sys.argv
    plan, held, total = [], [], 0
    for src in SOURCES:
        if not os.path.isdir(src):
            continue
        for dp, dn, fn in os.walk(src):
            dn[:] = [d for d in dn if d not in SKIP_DIRS and not d.startswith(".")]
            if os.path.realpath(dp).startswith(os.path.realpath(DEST)):
                continue
            for f in fn:
                if f.startswith((".", "~$")) or os.path.splitext(f)[1].lower() not in DOCS:
                    continue
                p = os.path.join(dp, f)
                rel = os.path.relpath(p, src)
                parts = [d.lower().strip() for d in os.path.dirname(rel).split(os.sep)]
                ext = os.path.splitext(f)[1].lower()
                nice = f.lower().replace("_", " ").replace("-", " ")
                if NOT_FOR_TEAM.search(nice) or NOT_FOR_TEAM.search(os.path.dirname(rel).replace("_", " ")):
                    continue                     # not training material
                if ext in {".txt", ".md", ".csv", ".svg", ".ai", ".psd", ".indd", ".eps"} and not KEEP_TEXT.search(nice):
                    continue                     # raw text, build blocks, design sources
                if ext in IMAGE and not POST_IMAGE.search(nice):
                    continue                     # raw images used to make posts and reels
                if CREDENTIAL.search(rel):
                    continue                     # logins: never copied, never listed
                why = None
                if any(PRIVATE_DIR.match(d) for d in parts):
                    why = "patient or ID folder"
                elif PERSONAL_ID.search(f.replace("_", " ")):
                    why = "personal ID"
                elif PATIENT_NAME.search(f.replace("_", " ")):
                    why = "looks like a patient record"
                else:
                    why = identifiers(p)
                if why:
                    held.append("%s   [%s]" % (p, why))
                    continue
                size = os.path.getsize(p)
                plan.append((p, classify(rel), size))
                total += size
    import hashlib
    def norm(p):
        b = os.path.basename(p).lower()
        b = re.sub(r"\s*\(\d+\)|\s*copy\b|_v?\d+(\.\d+)?(?=\.)", "", b)
        b = re.sub(r"^\d\d[_ ]", "", b)
        b = re.sub(r"bluewater[- ]metabolic[- ]and[- ]clinical[- ]services[- ]", "", b)
        return re.sub(r"[^a-z0-9.]", "", b.replace("bmwc", "bluewater").replace("men s", "mens").replace("women s", "womens"))
    best = {}
    for item in plan:
        k = norm(item[0])
        if k not in best or os.path.getmtime(item[0]) > os.path.getmtime(best[k][0]):
            best[k] = item
    seen, deduped = set(), []
    for item in sorted(best.values(), key=lambda i: -os.path.getmtime(i[0])):
        h = hashlib.sha1(open(item[0], "rb").read()).hexdigest()
        if h not in seen:
            seen.add(h); deduped.append(item)
    plan = deduped
    total = sum(i[2] for i in plan)
    by = {}
    for p, folder, size in plan:
        by.setdefault(folder, []).append((p, size))
    print("Team folder: %s" % DEST)
    print("Looked in: %s" % ", ".join(s for s in SOURCES if os.path.isdir(s)) or "nothing found")
    for folder in sorted(by):
        items = by[folder]
        print("\n%s  (%d files, %s)" % (folder, len(items), human(sum(s for _, s in items))))
        for p, _ in items[:8]:
            print("   " + os.path.basename(p))
        if len(items) > 8:
            print("   ... and %d more" % (len(items) - 8))
    print("\nHeld back for privacy review (not copied): %d" % len(held))
    for p in held[:10]:
        print("   " + p.replace(HOME, "~"))
    print("\nTotal to copy: %d files, %s" % (len(plan), human(total)))
    if not go:
        print("\nPreview only. Nothing was copied. If this looks right, run again with --go")
        return 0
    free = shutil.disk_usage(HOME).free
    if total > free * 0.8:
        print("Not enough free disk space for the copies. Free some space first.")
        return 1
    for top, subs in TREE.items():
        os.makedirs(os.path.join(DEST, top), exist_ok=True)
        for s in subs:
            os.makedirs(os.path.join(DEST, top, s), exist_ok=True)
    copied = skipped = 0
    for p, folder, size in plan:
        target = os.path.join(DEST, folder, os.path.basename(p))
        if os.path.exists(target):
            if os.path.getsize(target) == size:
                skipped += 1
                continue
            base, ext = os.path.splitext(target)
            n = 2
            while os.path.exists("%s (%d)%s" % (base, n, ext)):
                n += 1
            target = "%s (%d)%s" % (base, n, ext)
        shutil.copy2(p, target)
        copied += 1
    start = os.path.join(DEST, "00 Start Here")
    with open(os.path.join(start, "Read me first.txt"), "w") as f:
        f.write(README.replace("{date}", datetime.date.today().isoformat()))
    with open(os.path.join(os.path.dirname(DEST), "Held back for privacy review - PAUL ONLY.txt"), "w") as f:
        f.write("These files looked like patient records, so they were NOT put in the team folder.\n"
                "Check each one. Share only blank templates, never a completed or signed form.\n\n")
        f.write("\n".join(p.replace(HOME, "~") for p in held) + "\n")
    print("\nDone: %d copied, %d already there. Open: %s" % (copied, skipped, DEST))
    print("Check '99 To Sort' and move anything there into the right folder.")
    return 0


README = """Bluewater Metabolic & Clinical Services: Files For Team\n(staff review, training and resources)
Updated {date}

What's where
01 Policies & Procedures ............ clinic policies, IPAC, privacy (PHIPA), emergency procedures
02 Clinical Guidelines & References .. guidelines and references the clinic follows
03 Treatment Plans & Care Pathways ... approved plan templates and pathways
04 Forms & Templates ................. BLANK forms only: intake and consent, screening tools,
                                       occupational health, referrals, billing
05 Patient Education & Brochures ..... handouts and brochures given to patients
06 Social Media & Reels .............. finished reels, posts and ads (for review)
07 Staff Onboarding & Training ....... orientation and training material
08 Clinic Operations ................. schedules, contacts, equipment and supply logs
99 To Sort ........................... new files waiting to be filed

Rules for everyone
1. No patient information in this folder, ever. No completed or signed forms, charts, results
   or anything with a name, date of birth or health card number. Those stay in the clinic's
   records system.
2. Use the newest version. Don't keep "final-final" copies; replace the old file.
3. Public material says "Nurse Practitioner-led". Never "doctor" or "physician".
4. Clinical content (guidelines, treatment plans) changes only with the clinical lead's approval.
5. Name files clearly: what it is, then the date, e.g. "Consent - TB skin test - 2026-11.pdf".

Questions: ask Paul.
"""

if __name__ == "__main__":
    sys.exit(main())
