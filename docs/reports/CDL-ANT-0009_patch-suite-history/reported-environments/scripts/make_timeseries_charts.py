"""Time-series charts for CDL-ANT-0009: how reported environments shifted as
issue/PR volume ramped up. Reads ../data/families.json, ../catalog.json,
and ../data/issue_dates.json (run fetch_issue_dates.py first). NCL Graphite +
Copper house theme, matching make_charts.py. Run:
  python3 scripts/make_timeseries_charts.py
"""
import json, os, collections, datetime as dt
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager as fm
from matplotlib.ticker import FuncFormatter
import matplotlib.dates as mdates

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
OUT = os.path.join(ROOT, "charts")
os.makedirs(OUT, exist_ok=True)

fams = json.load(open(os.path.join(ROOT, "data", "families.json")))
catalog = json.load(open(os.path.join(ROOT, "catalog.json")))
dates_doc = json.load(open(os.path.join(ROOT, "data", "issue_dates.json")))
DATES = {int(k): dt.datetime.fromisoformat(v["createdAt"].replace("Z", "+00:00")).replace(tzinfo=None)
         for k, v in dates_doc["dates"].items()}
CLOSED_DATES = {int(k): dt.datetime.fromisoformat(v["closedAt"].replace("Z", "+00:00")).replace(tzinfo=None)
                for k, v in dates_doc["dates"].items() if v.get("closedAt")}

# ---- Graphite + Copper (NCL house palette) ----
NAVY = "#30343A"; NAVY_D = "#1A1B1E"; GOLD = "#B05B33"; SLATE = "#5C616A"
INK = "#181B20"; GRID = "#E2E4E8"; SURF = "#ffffff"; GREEN = "#2e7d52"
GREY = "#C2C6CC"; GOLD_L = "#E2B89C"
FAMILY_COLORS = [NAVY, GOLD, SLATE, GREEN, GOLD_L]

for cand in ["Public Sans", "DejaVu Sans", "Liberation Sans", "Arial"]:
    if any(cand.lower() in f.name.lower() for f in fm.fontManager.ttflist):
        plt.rcParams["font.family"] = cand; break
plt.rcParams.update({"font.size": 12, "text.color": INK, "axes.labelcolor": INK,
    "xtick.color": INK, "ytick.color": INK, "axes.edgecolor": GRID, "axes.linewidth": 1.0,
    "figure.dpi": 200, "savefig.dpi": 200})


def style(ax):
    ax.spines["top"].set_visible(False); ax.spines["right"].set_visible(False)
    ax.grid(True, color=GRID, linewidth=0.8, alpha=0.7); ax.set_axisbelow(True)


INFLECT = dt.datetime(2026, 1, 22)  # same inflection as NCL-CDD-0001: sustained AI-assisted build-out begins

# =====================================================================
# Shared weekly binning: a complete, zero-filled week range (no gaps for
# silent weeks) plus a trailing-average smoother for the noisy raw series.
# The current, still-accruing week is dropped so charts don't end on a cliff.
# =====================================================================
ALL_DATES_SORTED = sorted(DATES.values())
FIRST_DAY, LAST_DAY = ALL_DATES_SORTED[0].date(), ALL_DATES_SORTED[-1].date()


def week_start(d):
    return d - dt.timedelta(days=d.weekday())  # Monday


def date_range(start, end, step_days):
    d, out = start, []
    while d <= end:
        out.append(d)
        d += dt.timedelta(days=step_days)
    return out


CURRENT_WEEK = week_start(LAST_DAY)
WEEKS = date_range(week_start(FIRST_DAY), CURRENT_WEEK - dt.timedelta(days=7), 7)
WEEK_DT = [dt.datetime(w.year, w.month, w.day) for w in WEEKS]


def weekly_counts(items, date_map=None):
    date_map = date_map if date_map is not None else DATES
    c = collections.Counter(week_start(date_map[n].date()) for n in items if n in date_map)
    return np.array([c.get(w, 0) for w in WEEKS], dtype=float)


def trailing_avg(vals, window):
    out = np.full(len(vals), np.nan)
    for i in range(len(vals)):
        lo = max(0, i - window + 1)
        out[i] = vals[lo:i + 1].mean()
    return out


def family_trend_chart(entries, top_n, filename, title, window=4, mark_inflection=False):
    """Weekly trailing-average line per top family, plus the category total
    (raw weekly bars + its own trailing average) as shared context."""
    top = entries[:top_n]
    total_items = set().union(*(e["items"] for e in entries))
    total_wk = weekly_counts(total_items)
    total_avg = trailing_avg(total_wk, window)

    fig, ax = plt.subplots(figsize=(10.4, 4.8))
    ax.bar(WEEK_DT, total_wk, width=6, color=GRID, edgecolor="none", zorder=1,
           label="Total, all values (raw, that week)")
    ax.plot(WEEK_DT, total_avg, color=INK, lw=2.6, ls=(0, (5, 2)), zorder=5,
            label=f"Total ({window}-wk avg)")
    for e, color in zip(top, FAMILY_COLORS):
        avg = trailing_avg(weekly_counts(e["items"]), window)
        ax.plot(WEEK_DT, avg, color=color, lw=2.1, zorder=4, label=f"{e['name']} ({window}-wk avg)")

    ax.set_xlim(WEEK_DT[0] - dt.timedelta(days=4), WEEK_DT[-1] + dt.timedelta(days=4))
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%b\n%Y"))
    ax.xaxis.set_major_locator(mdates.MonthLocator(interval=2))
    ax.set_ylabel("Issues/PRs opened per week")
    ax.set_title(title, fontweight="bold", fontsize=13.5, loc="left", color=INK, pad=10)
    if mark_inflection:
        _id = mdates.date2num(INFLECT)
        ax.axvline(_id, color=INK, lw=1.2, ls=(0, (4, 3)), alpha=0.85, zorder=6)
        ax.annotate("Sustained AI-assisted\nbuild-out begins\n(Jan 2026)",
                    xy=(_id, total_wk.max() * 0.42), xytext=(dt.datetime(2025, 6, 15), total_wk.max() * 0.3),
                    fontsize=9, color=INK, ha="left", va="center",
                    bbox=dict(boxstyle="round,pad=0.3", fc="white", ec=GRID, alpha=0.95),
                    arrowprops=dict(arrowstyle="->", color=INK, lw=1.1), zorder=7)
    style(ax); ax.grid(axis="x", alpha=0)
    ax.legend(loc="upper left", ncol=3, frameon=False, fontsize=8.5)
    fig.tight_layout()
    fig.savefig(f"{OUT}/{filename}", bbox_inches="tight", facecolor=SURF)
    plt.close(fig)


# =====================================================================
# CHART 1 - Distro families, weekly trailing averages + total
# =====================================================================
family_trend_chart(fams["distros"], 5, "chart_distros_over_time.png",
                    "Distro-family reports per week (4-week trailing average)", mark_inflection=True)

# =====================================================================
# CHART 2 - Desktop environment families, weekly trailing averages + total
# =====================================================================
family_trend_chart(fams["desktopEnvironments"], 5, "chart_desktop_environments_over_time.png",
                    "Desktop-environment-family reports per week (4-week trailing average)")

# =====================================================================
# CHART 3 - Compositors/WMs, weekly trailing averages + total
# =====================================================================
family_trend_chart(fams["compositors"], 5, "chart_compositors_over_time.png",
                    "Compositor/WM reports per week (4-week trailing average)")

# =====================================================================
# CHART 4 - Package formats, weekly trailing averages + total
# =====================================================================
family_trend_chart(fams["packageFormats"], 4, "chart_formats_over_time.png",
                    "Package-format reports per week (4-week trailing average)")

# =====================================================================
# CHART 5 - Session-type share over time (100%-stacked, quarterly)
# =====================================================================
session_items = {e["name"]: set(e["items"]) for e in catalog["sessionTypes"] if e["name"] != "XRDP"}
LAST_FULL_MONTH_END = max(DATES.values()).replace(day=1) - dt.timedelta(days=1)
LAST_FULL_Q = f"{LAST_FULL_MONTH_END.year}-Q{(LAST_FULL_MONTH_END.month-1)//3+1}"
QUARTERS = sorted({f"{d.year}-Q{(d.month-1)//3+1}" for d in DATES.values()})
QUARTERS = [q for q in QUARTERS if q <= LAST_FULL_Q]
QUARTER_DT = [dt.datetime(int(q.split("-Q")[0]), (int(q.split("-Q")[1]) - 1) * 3 + 1, 1) for q in QUARTERS]


def quarterly_counts(items):
    c = collections.Counter()
    for n in items:
        d = DATES.get(n)
        if d:
            c[f"{d.year}-Q{(d.month-1)//3+1}"] += 1
    return np.array([c.get(q, 0) for q in QUARTERS], dtype=float)


SESSIONS = ["X11", "Wayland", "XWayland"]
SCOL = {"X11": SLATE, "Wayland": GOLD, "XWayland": GOLD_L}
SM = np.vstack([quarterly_counts(session_items[s]) for s in SESSIONS])
tot = SM.sum(axis=0); tot[tot == 0] = 1
share = SM / tot * 100.0

fig, ax = plt.subplots(figsize=(9.5, 4.6))
ax.stackplot(QUARTER_DT, share, labels=SESSIONS, colors=[SCOL[s] for s in SESSIONS],
             edgecolor="white", linewidth=0.4)
ax.set_ylim(0, 100); ax.set_xlim(QUARTER_DT[0], QUARTER_DT[-1])
ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{int(v)}%"))
ax.xaxis.set_major_formatter(mdates.DateFormatter("%b\n%Y"))
ax.set_title("Session-type mix of reports, by quarter", fontweight="bold",
             fontsize=13.5, loc="left", color=INK, pad=10)
style(ax); ax.grid(axis="x", alpha=0)
ax.legend(loc="lower center", ncol=3, frameon=False, fontsize=9.5, bbox_to_anchor=(0.5, -0.24))
fig.tight_layout()
fig.savefig(f"{OUT}/chart_sessions_over_time.png", bbox_inches="tight", facecolor=SURF)
plt.close(fig)

# =====================================================================
# CHART 6 - Opened vs. closed per week, all categories combined (4-week
# trailing averages). Closed reports are mirrored below the zero line so
# opened/closed volume can be compared at a glance, diverging-bar style.
# =====================================================================
opened_vals = weekly_counts(set(DATES.keys()))
opened_avg = trailing_avg(opened_vals, 4)
closed_vals = weekly_counts(set(CLOSED_DATES.keys()), date_map=CLOSED_DATES)
closed_avg = trailing_avg(closed_vals, 4)

fig, ax = plt.subplots(figsize=(10.2, 5.0))
ax.bar(WEEK_DT, opened_vals, width=6, color=GRID, edgecolor=SLATE, linewidth=0.4,
       label="Opened that week", zorder=2)
ax.bar(WEEK_DT, -closed_vals, width=6, color=GOLD_L, edgecolor=GOLD, linewidth=0.4,
       label="Closed that week", zorder=2)
ax.plot(WEEK_DT, opened_avg, color=GOLD, lw=2.4, zorder=4, label="Opened (4-wk avg)")
ax.plot(WEEK_DT, -closed_avg, color=NAVY, lw=2.4, zorder=4, label="Closed (4-wk avg)")
ax.axhline(0, color=INK, lw=1.0, zorder=3)
ax.set_xlim(WEEK_DT[0] - dt.timedelta(days=4), WEEK_DT[-1] + dt.timedelta(days=4))
ax.xaxis.set_major_formatter(mdates.DateFormatter("%b\n%Y"))
ax.xaxis.set_major_locator(mdates.MonthLocator(interval=2))
ax.yaxis.set_major_formatter(FuncFormatter(lambda v, _: f"{abs(int(v))}"))
ax.set_ylabel("Issues/PRs, per week  (opened above / closed below)")
ax.set_title("Reports opened vs. closed per week — all categories combined", fontweight="bold",
             fontsize=13, loc="left", color=INK, pad=10)
_id = mdates.date2num(INFLECT)
ax.axvline(_id, color=INK, lw=1.2, ls=(0, (4, 3)), alpha=0.85, zorder=5)
style(ax); ax.grid(axis="x", alpha=0)
ax.legend(loc="upper left", ncol=2, frameon=False, fontsize=9.5)
fig.tight_layout()
fig.savefig(f"{OUT}/chart_reports_per_week.png", bbox_inches="tight", facecolor=SURF)
plt.close(fig)

print("timeseries charts: distros_over_time, desktop_environments_over_time, compositors_over_time, "
      "formats_over_time, sessions_over_time, reports_per_week")
print(f"week range: {WEEKS[0]} .. {WEEKS[-1]}  ({len(DATES)} dated items)")
