#!/usr/bin/env python3
"""Build ~/Desktop/BWMCS/Files For Team and sort COPIES of clinic files into it.

  python3 make-team-folder.py          preview only: shows where every file would go
  python3 make-team-folder.py --go     builds the folder and copies the files

Your original files are never moved, renamed or deleted. Run it again any time: files already
copied are skipped, so only new ones are added.

Patient privacy: anything whose name or folder looks like a patient record (charts, results,
signed or completed forms, dates of birth, health card numbers) is NOT copied. It is listed in
"00 Start Here/Held back for privacy review.txt" so you can decide by hand.
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
    "06 Marketing & Advertising": ["Reels & Videos", "Social Media Graphics", "Print & Digital Ads",
                                   "Brand Assets (logos, colours)"],
    "07 Staff Onboarding & Training": [],
    "08 Clinic Operations": [],
    "99 To Sort": [],
}

# Order matters: the first rule that matches wins.
RULES = [
    (r"\b(logo|brand|colou?r ?palette|letterhead|business ?card|style ?guide)\b", "06 Marketing & Advertising/Brand Assets (logos, colours)"),
    (r"\b(flyer|poster|advert|ads?|banner|campaign|billboard|postcard|promo)\b", "06 Marketing & Advertising/Print & Digital Ads"),
    (r"\b(reel|instagram|facebook|tiktok|youtube|linkedin|social|story|caption|thumbnail)\b", "06 Marketing & Advertising/Social Media Graphics"),
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

# Looks like a patient record: never copied.
PRIVATE = re.compile(
    r"\b(chart|charts|patient ?file|patient ?record|results?|lab ?results?|bloodwork|signed|completed|filled|"
    r"scanned|discharge|progress ?note|soap ?note|encounter|visit ?note|prescription|rx|dob|ohip|health ?card|"
    r"hcn|mrn|resident)\b"
    r"|\b\d{4}[- ]?\d{3}[- ]?\d{3}\b"                      # health card number
    r"|\b(19|20)\d{2}[-_.](0[1-9]|1[0-2])[-_.](0[1-9]|[12]\d|3[01])\b.*\b[A-Z][a-z]+\b",  # date + a name
    re.I)
# Any file inside a folder with one of these names is treated as a patient record.
PRIVATE_DIR = re.compile(r"^(patients?|patient files|clients?|charts?|records?|residents?|medical records|emr|scans?)$")
SKIP_DIRS = {"Files For Team", ".git", "node_modules", "Library", ".Trash", "PMPBrain"}


def classify(path):
    rel = path.lower().replace("_", " ").replace("-", " ")
    name = os.path.basename(rel)
    ext = os.path.splitext(name)[1]
    if ext in VIDEO:
        return "06 Marketing & Advertising/Reels & Videos"
    for rx, folder in RULES:
        if re.search(rx, name):
            return folder
    for rx, folder in RULES:                    # fall back to the folder names around the file
        if re.search(rx, os.path.dirname(rel)):
            return folder
    if ext in IMAGE and re.search(r"advert|market|reel|social|promo", rel):
        return "06 Marketing & Advertising/Social Media Graphics"
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
                if PRIVATE.search(rel.replace("_", " ")) or any(PRIVATE_DIR.match(d) for d in parts):
                    held.append(p)
                    continue
                size = os.path.getsize(p)
                plan.append((p, classify(rel), size))
                total += size
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
    with open(os.path.join(start, "Held back for privacy review.txt"), "w") as f:
        f.write("These files looked like patient records, so they were NOT put in the team folder.\n"
                "Check each one. Share only blank templates, never a completed or signed form.\n\n")
        f.write("\n".join(p.replace(HOME, "~") for p in held) + "\n")
    print("\nDone: %d copied, %d already there. Open: %s" % (copied, skipped, DEST))
    print("Check '99 To Sort' and move anything there into the right folder.")
    return 0


README = """Bluewater Metabolic & Clinical Services: Files For Team
Updated {date}

What's where
01 Policies & Procedures ............ clinic policies, IPAC, privacy (PHIPA), emergency procedures
02 Clinical Guidelines & References .. guidelines and references the clinic follows
03 Treatment Plans & Care Pathways ... approved plan templates and pathways
04 Forms & Templates ................. BLANK forms only: intake and consent, screening tools,
                                       occupational health, referrals, billing
05 Patient Education & Brochures ..... handouts and brochures given to patients
06 Marketing & Advertising ........... reels, social graphics, print ads, logos and brand colours
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
