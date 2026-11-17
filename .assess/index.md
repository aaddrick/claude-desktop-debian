<!-- assess:run_id=20261117132553-ba7d748c artifact_schema_version=1.4.0 -->
# Assess Wiki Index

_Last updated: 2026-11-17_

Catalog of every hotspot ever flagged by `/assess` in this repo. Status reflects the most recent run.

| File | First Flagged | Last Seen | Status | Latest CCN | Latest LOC |
|------|---------------|-----------|--------|------------|------------|
| `scripts/launcher-common.sh` | 2026-11-17 | 2026-11-17 | new | 208.0 | 1229 |
| `scripts/cowork-fallback/cowork-vm-service.js` | 2026-11-17 | 2026-11-17 | new | 635.0 | 2256 |
| `tests/test-artifact-common.sh` | 2026-11-17 | 2026-11-17 | new | 103.0 | 581 |
| `build.sh` | 2026-11-17 | 2026-11-17 | new | 52.0 | 239 |
| `scripts/packaging/deb.sh` | 2026-11-17 | 2026-11-17 | new | 77.0 | 291 |
| `scripts/patches/app-asar.sh` | 2026-11-17 | 2026-11-17 | new | 49.0 | 235 |
| `scripts/packaging/rpm.sh` | 2026-11-17 | 2026-11-17 | new | 49.0 | 253 |
| `scripts/doctor.sh` | 2026-11-17 | 2026-11-17 | new | 5.0 | 2150 |
| `scripts/packaging/appimage.sh` | 2026-11-17 | 2026-11-17 | new | 50.0 | 262 |
| `scripts/setup/detect-host.sh` | 2026-11-17 | 2026-11-17 | new | 49.0 | 176 |

## Legend

- **active** - in the latest top hotspots list
- **new** - newly entered the hotspot list this run
- **graduated** - was a hotspot, no longer is (good)
- **regressed** - still a hotspot, and getting worse. Any of: its worst function rose; its summed complexity rose by more than the worst function fell (an aggregate rise larger than the worst-function fall); or the worst function is flat or unmeasured and the sum or churn rose
- **restructured** - still a hotspot; the sum or churn rose but the worst function fell by at least as much as the sum rose, the shape a split into named helpers leaves (good)
- **persistent** - still a hotspot, roughly unchanged
- **retired** - the source file was deleted or excluded; the page is kept for history

## How this gets updated

Each `/assess` run reads this file, the prior `complexity-stats.json`, and the latest run output, then rewrites this index. A file the latest run did not rank keeps its last known row, so no hotspot drops out of the catalog. Per-file detail lives in `hotspots/<slug>.md`. Run history lives in `log.md`.
