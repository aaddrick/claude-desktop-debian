"""Collapse version/edition variants within each catalog category into base
families (e.g. "Ubuntu 24.04.2 LTS" / "Ubuntu 22.04+" -> "Ubuntu"; "KDE Plasma
6.6.4" -> "KDE Plasma"). Distinct product names are NOT merged into each
other (Kubuntu stays separate from Ubuntu, CachyOS from Arch Linux) -- only
literal version/build/codename suffixes on the SAME name are stripped.

Reads ../catalog.json, writes ../data/families.json. Run:
  python3 scripts/group_families.py
"""
import json, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
catalog = json.load(open(os.path.join(ROOT, "catalog.json")))

CODENAMES = {"jammy", "noble", "focal", "bookworm", "trixie", "sid",
             "bullseye", "buster", "unstable", "stable", "testing",
             "trixie/sid"}
ALIASES = {"Kali": "Kali Linux", "Debian-based Linux": "Debian",
           "Debian/Ubuntu": "Debian"}
VERSION_RE = re.compile(r"\s+v?\d+(\.(?:\d+|x))*(-\d+)?\+?$")
LTS_RE = re.compile(r"\s+LTS$", re.I)
PAREN_RE = re.compile(r"\s*\([^)]*\)\s*$")
ROLLING_RE = re.compile(r"\s+GNU/Linux Rolling.*$", re.I)


def base_name(name):
    n = name
    n = PAREN_RE.sub("", n)
    n = ROLLING_RE.sub("", n)
    n = LTS_RE.sub("", n)
    changed = True
    while changed:
        changed = False
        last_word = n.rsplit(" ", 1)[-1].lower()
        if last_word in CODENAMES and " " in n:
            n = n.rsplit(" ", 1)[0]
            changed = True
        m = VERSION_RE.match("") # no-op placeholder for readability
        new_n = VERSION_RE.sub("", n)
        if new_n != n:
            n = new_n
            changed = True
    n = n.strip()
    return ALIASES.get(n, n)


def group(entries):
    """entries: list of {name, items}. Returns list of {name, items, members}
    sorted by descending distinct-item count, items deduplicated + sorted."""
    families = {}
    for e in entries:
        fam = base_name(e["name"])
        rec = families.setdefault(fam, {"name": fam, "items": set(), "members": {}})
        rec["items"].update(e["items"])
        rec["members"][e["name"]] = len(e["items"])
    out = []
    for fam, rec in families.items():
        members = sorted(rec["members"].items(), key=lambda kv: -kv[1])
        out.append({
            "name": fam,
            "count": len(rec["items"]),
            "items": sorted(rec["items"]),
            "members": [{"name": m, "count": c} for m, c in members],
        })
    out.sort(key=lambda r: -r["count"])
    return out


GROUPED_CATEGORIES = ["distros", "desktopEnvironments", "compositors"]
PASSTHROUGH_CATEGORIES = ["sessionTypes", "packageFormats"]

result = {}
for cat in GROUPED_CATEGORIES:
    result[cat] = group(catalog[cat])
for cat in PASSTHROUGH_CATEGORIES:
    result[cat] = [{"name": e["name"], "count": len(e["items"]), "items": sorted(e["items"])}
                    for e in sorted(catalog[cat], key=lambda e: -len(e["items"]))]

os.makedirs(os.path.join(ROOT, "data"), exist_ok=True)
out_path = os.path.join(ROOT, "data", "families.json")
json.dump(result, open(out_path, "w"), indent=2)

for cat in GROUPED_CATEGORIES:
    before = len(catalog[cat])
    after = len(result[cat])
    print(f"{cat}: {before} raw strings -> {after} families")
    for fam in result[cat][:6]:
        variants = "" if len(fam["members"]) == 1 else f"  [{len(fam['members'])} variants]"
        print(f"  {fam['name']:<22} {fam['count']:>4}{variants}")
print(f"wrote {out_path}")
