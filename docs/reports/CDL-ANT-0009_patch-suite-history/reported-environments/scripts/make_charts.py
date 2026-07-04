"""Reported-environment charts for CDL-ANT-0009 (patch-suite history report).

Reads ../data/families.json (version/edition variants collapsed within each
category -- see group_families.py) plus ../catalog.json (raw session-type
data, for the cross-cut chart). NCL Graphite + Copper house theme, matching
NCL-CDD-0001's scripts/make_charts.py. Run:
  python3 scripts/make_charts.py
"""
import json, os
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager as fm
from matplotlib.patches import Patch

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
OUT = os.path.join(ROOT, "charts")
os.makedirs(OUT, exist_ok=True)

fams = json.load(open(os.path.join(ROOT, "data", "families.json")))
catalog = json.load(open(os.path.join(ROOT, "catalog.json")))

# ---- Graphite + Copper (NCL house palette) ----
NAVY = "#30343A"; NAVY_D = "#1A1B1E"; GOLD = "#B05B33"; SLATE = "#5C616A"
INK = "#181B20"; GRID = "#E2E4E8"; SURF = "#ffffff"; GREEN = "#2e7d52"
GREY = "#C2C6CC"; GOLD_L = "#E2B89C"

for cand in ["Public Sans", "DejaVu Sans", "Liberation Sans", "Arial"]:
    if any(cand.lower() in f.name.lower() for f in fm.fontManager.ttflist):
        plt.rcParams["font.family"] = cand; break
plt.rcParams.update({"font.size": 12, "text.color": INK, "axes.labelcolor": INK,
    "xtick.color": INK, "ytick.color": INK, "axes.edgecolor": GRID, "axes.linewidth": 1.0,
    "figure.dpi": 200, "savefig.dpi": 200})


def style(ax):
    ax.spines["top"].set_visible(False); ax.spines["right"].set_visible(False)
    ax.grid(True, color=GRID, linewidth=0.8, alpha=0.7); ax.set_axisbelow(True)


def hbar(ax, rows, unit_label, color_fn, title, note=None):
    """rows: list of (label, count, extra_label_suffix)."""
    y = np.arange(len(rows))[::-1]
    vals = [r[1] for r in rows]
    bars = ax.barh(y, vals, color=[color_fn(r[0]) for r in rows], height=0.64,
                    edgecolor="white", linewidth=0.6)
    ax.set_yticks(y); ax.set_yticklabels([r[0] for r in rows], fontsize=10)
    ax.set_xlim(0, max(vals) * 1.24)
    for b, r in zip(bars, rows):
        suffix = f"  {r[2]}" if len(r) > 2 and r[2] else ""
        ax.text(b.get_width() + max(vals) * 0.015, b.get_y() + b.get_height() / 2,
                 f"{r[1]}{suffix}", va="center", fontsize=9, color=INK)
    ax.set_title(title, fontweight="bold", fontsize=13, loc="left", color=INK, pad=10)
    style(ax); ax.grid(axis="y", alpha=0)
    ax.xaxis.set_visible(False); ax.spines["bottom"].set_visible(False)
    if note:
        ax.text(0, -1.15, note, fontsize=8.6, color=SLATE, transform=ax.get_yaxis_transform())


# =====================================================================
# CHART 1 - Distro families (versions collapsed)
# =====================================================================
top = fams["distros"][:12]
rows = []
for f in top:
    nv = len(f["members"])
    rows.append((f["name"], f["count"], f"({nv} versions merged)" if nv > 1 else ""))
fig, ax = plt.subplots(figsize=(9, 5.4))
hbar(ax, rows, "issues/PRs", lambda n: NAVY, "Distro families reported across issues & PRs",
     note="Versioned mentions (Ubuntu 24.04, 22.04, ...) merged into their base distro; distinct products (Kubuntu, Pop!_OS, CachyOS) kept separate.")
fig.tight_layout()
fig.savefig(f"{OUT}/chart_distro_families.png", bbox_inches="tight", facecolor=SURF)
plt.close(fig)

# =====================================================================
# CHART 2 - Desktop environment families
# =====================================================================
rows = []
for f in fams["desktopEnvironments"]:
    nv = len(f["members"])
    rows.append((f["name"], f["count"], f"({nv} versions merged)" if nv > 1 else ""))
fig, ax = plt.subplots(figsize=(9, 4.6))
hbar(ax, rows, "issues/PRs", lambda n: GOLD if n in ("GNOME", "KDE Plasma") else NAVY,
     "Desktop environment families reported")
fig.tight_layout()
fig.savefig(f"{OUT}/chart_desktop_environments.png", bbox_inches="tight", facecolor=SURF)
plt.close(fig)

# =====================================================================
# CHART 3 - Compositors / window managers, split standalone-tiling vs DE-native
# =====================================================================
TILING = {"Hyprland", "Niri", "Sway", "i3", "dwm", "river", "xmonad", "bspwm"}
DE_NATIVE = {"KWin", "Mutter", "Muffin", "cosmic-comp"}
rows = [(f["name"], f["count"]) for f in fams["compositors"]]
fig, ax = plt.subplots(figsize=(9, 5.0))
hbar(ax, rows, "issues/PRs",
     lambda n: GOLD if n in TILING else (SLATE if n in DE_NATIVE else GREY),
     "Compositors and window managers named explicitly")
fig.legend(handles=[Patch(color=GOLD, label="Standalone tiling WM (Wayland-first)"),
                     Patch(color=SLATE, label="A DE's own compositor, named directly"),
                     Patch(color=GREY, label="Shared library (wlroots)")],
           loc="lower center", ncol=1, frameon=False, fontsize=9, bbox_to_anchor=(0.72, 0.15))
fig.tight_layout()
fig.savefig(f"{OUT}/chart_compositors.png", bbox_inches="tight", facecolor=SURF)
plt.close(fig)

# =====================================================================
# CHART 4 - Environment (DE families + tiling-WM bucket) x session type
# Grouped bars, not stacked-to-100%: a report can name more than one session
# type, so totals per environment are not mutually exclusive.
# =====================================================================
session_items = {e["name"]: set(e["items"]) for e in catalog["sessionTypes"]}
comp_items = {f["name"]: set(f["items"]) for f in fams["compositors"]}
tiling_items = set().union(*(comp_items[n] for n in TILING if n in comp_items))
de_items = {f["name"]: set(f["items"]) for f in fams["desktopEnvironments"]}
ENVS = [("GNOME", de_items["GNOME"]), ("KDE Plasma", de_items["KDE Plasma"]),
        ("XFCE", de_items["XFCE"]), ("Cinnamon", de_items["Cinnamon"]),
        ("COSMIC", de_items["COSMIC"]), ("Tiling WM\n(Hyprland/Niri/Sway/i3/...)", tiling_items)]
SESSIONS = ["X11", "Wayland", "XWayland"]
SCOL = {"X11": SLATE, "Wayland": GOLD, "XWayland": GOLD_L}

fig, ax = plt.subplots(figsize=(10.5, 5.2))
n = len(ENVS); w = 0.25
x = np.arange(n)
for i, s in enumerate(SESSIONS):
    vals = [len(items & session_items[s]) for _, items in ENVS]
    bars = ax.bar(x + (i - 1) * w, vals, width=w, color=SCOL[s], label=s,
                   edgecolor="white", linewidth=0.5)
    for b, v in zip(bars, vals):
        ax.text(b.get_x() + b.get_width() / 2, v + 1.2, f"{v}", ha="center",
                 fontsize=8.3, color=INK)
ax.set_xticks(x); ax.set_xticklabels([e[0] for e in ENVS], fontsize=9.5)
ax.set_ylabel("Issues/PRs mentioning this session type")
ax.set_title("Tiling-WM users are reporting almost exclusively on Wayland; DE users still split",
             fontweight="bold", fontsize=12.5, loc="left", color=INK, pad=10)
ax.legend(frameon=False, fontsize=9.5, loc="upper right")
style(ax); ax.grid(axis="x", alpha=0)
fig.tight_layout()
fig.savefig(f"{OUT}/chart_environment_sessions.png", bbox_inches="tight", facecolor=SURF)
plt.close(fig)

# =====================================================================
# CHART 5 - Package formats and install channels
# =====================================================================
FORMATS = {"deb", "AppImage", "RPM", "DMG", "tarball", "PKGBUILD", "source/manual build"}
rows = [(f["name"], f["count"]) for f in fams["packageFormats"] if f["name"] not in (".desktop", "systemd user service")]
fig, ax = plt.subplots(figsize=(9, 6.0))
hbar(ax, rows, "issues/PRs", lambda n: NAVY if n in FORMATS else GOLD,
     "Package formats vs. the install channels people used to get them")
fig.legend(handles=[Patch(color=NAVY, label="Installable artifact / build method"),
                     Patch(color=GOLD, label="Package manager / repo channel")],
           loc="lower center", ncol=2, frameon=False, fontsize=9.5, bbox_to_anchor=(0.62, 0.14))
fig.tight_layout()
fig.savefig(f"{OUT}/chart_package_formats.png", bbox_inches="tight", facecolor=SURF)
plt.close(fig)

print("charts: distro_families, desktop_environments, compositors, environment_sessions, package_formats")
