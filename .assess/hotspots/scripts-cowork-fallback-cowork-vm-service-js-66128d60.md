<!-- assess:run_id=20261117132553-ba7d748c artifact_schema_version=1.4.0 -->
# Hotspot: `scripts/cowork-fallback/cowork-vm-service.js`

_First flagged: 2026-11-17. Last seen: 2026-11-17. Status: new._

## Current metrics

| Metric | Value |
|--------|-------|
| LOC | 2256 |
| Cyclomatic complexity (file aggregate) | 635 |
| Worst function | `startVM` (31) |
| Commits in churn window | 15 |
| Has test file | no |

## History across runs

| Run date | Run | LOC | CCN | Commits | Status |
|----------|-----|-----|-----|---------|--------|
| 2026-11-17 | ba7d748c | 2256 | 635 | 15 | new |

## Briefing for editing this file

Use this briefing when about to modify `scripts/cowork-fallback/cowork-vm-service.js`:

Hotspot (new). 2256 LOC, aggregate cyclomatic complexity 635 (worst function `startVM` 31), 15 commits in churn window. Carries 1 stale promissory marker(s) (todo; oldest survived 15 edits to this file). (Briefing refined by LLM via assess_finalize - see Suggested actions below.)

## Suggested actions

- Reword the comment at line 1663 so it describes the shipped #342 fix rather than reading as a promise
- Measure coverage of scripts/cowork-fallback/tests/ with c8 before refactoring startVM (fn ccn 31)

