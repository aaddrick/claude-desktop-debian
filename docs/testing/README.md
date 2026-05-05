# Linux Compatibility Testing

*Last updated: 2026-05-03*

This directory holds the manual test plan for the Linux fork of Claude Desktop. The structure is designed for human readers today and scripted runners tomorrow.

## Layout

| Folder / file | Purpose |
|---------------|---------|
| [`matrix.md`](./matrix.md) | **The dashboard.** Cross-environment results table + per-section env-specific status snapshots. Single source of truth for test status. |
| [`runbook.md`](./runbook.md) | How to run a sweep: VM setup, diagnostic capture, status update workflow, severity guidance. |
| [`cases/`](./cases/) | Functional test specs grouped by feature surface. Stable IDs: `T###` cross-env, `S###` env-specific. |

## Environment key

| Abbrev | Distro | DE | Display server |
|--------|--------|-----|----------------|
| KDE-W  | Fedora 43 | KDE Plasma | Wayland |
| KDE-X  | Fedora 43 | KDE Plasma | X11 |
| GNOME  | Fedora 43 | GNOME | Wayland |
| Ubu    | Ubuntu 24.04 | GNOME | Wayland |
| Sway   | Fedora 43 | Sway | Wayland (wlroots) |
| i3     | Fedora 43 | i3 | X11 |
| Niri   | Fedora 43 | Niri | Wayland (wlroots) |
| Hypr-O | OmarchyOS | Hyprland | Wayland (wlroots) |
| Hypr-N | NixOS | Hyprland | Wayland (wlroots) |

Status legend: `✓` pass · `✗` fail · `🔧` mitigated · `?` untested · `-` N/A

Cells include linked issue/PR numbers when relevant — e.g. `✗ #404` or `🔧 #406`. A bare `✗` means the failure is verified but no tracking issue is filed yet.

## Severity tiers

Each test is tagged with one of:

| Tier | Meaning | Sweep cadence |
|------|---------|---------------|
| **Smoke** | Release-gate. Must pass before any tag is cut. | Every release tag, on KDE-W + one wlroots row |
| **Critical** | Regression-blocker. Failure on any supported environment blocks the release. | Every release tag, on every active row |
| **Should** | Important but not blocking. Track as bugs, fix before next stable. | Quarterly + on demand |
| **Could** | Edge cases, nice-to-have. | On demand only |

## Smoke set

The minimum set that gates a release. Run on **KDE-W** (daily-driver) plus **Hypr-N** (clean wlroots). Sweep target: ~20 minutes.

| ID | Surface | One-line check |
|----|---------|----------------|
| [T01](./cases/launch.md#t01--app-launch) | Launch | App opens; main window renders within ~10s |
| [T03](./cases/tray-and-window-chrome.md#t03--tray-icon-present) | Tray | Tray icon appears; click toggles window |
| [T04](./cases/tray-and-window-chrome.md#t04--window-decorations-draw) | Window | OS-native frame draws and responds |
| [T05](./cases/shortcuts-and-input.md#t05--url-handler-opens-claudeai-links-in-app) | Input | `xdg-open https://claude.ai/...` opens in-app |
| [T07](./cases/tray-and-window-chrome.md#t07--in-app-topbar-renders--clickable) | Window | Hybrid topbar renders, every button clicks |
| [T08](./cases/tray-and-window-chrome.md#t08--hide-to-tray-on-close) | Window | Close button hides to tray, doesn't quit |
| [T11](./cases/extensibility.md#t11--plugin-install-anthropic--partners) | Extensibility | Anthropic & Partners plugin install completes |
| [T15](./cases/code-tab-foundations.md#t15--sign-in-completes-via-browser-handoff) | Auth | Sign-in completes via `xdg-open` browser handoff |
| [T16](./cases/code-tab-foundations.md#t16--code-tab-loads) | Code tab | Code tab loads (no 403, no blank screen) |
| [T17](./cases/code-tab-foundations.md#t17--folder-picker-opens) | Code tab | Folder picker opens via portal/native chooser |

## Test corpus snapshot

| Bucket | Count |
|--------|-------|
| Cross-environment functional (`T###`) | 39 |
| Environment-specific functional (`S###`) | 37 |
| UI surfaces inventoried | 10 |
| Total functional tests | 76 |

For detailed status by ID, see [`matrix.md`](./matrix.md).

## Automation status

Automation is partially landed. The harness lives at
[`tools/test-harness/`](../../tools/test-harness/) — twenty Playwright
specs wired (T01, T03, T04, T17, S09, S12, S29-S37, plus four H-prefix
self-tests), thirteen passing on KDE-W and six skipping cleanly per
spec intent. See [`tools/test-harness/README.md`](../../tools/test-harness/README.md)
for the live status table, [`automation.md`](./automation.md) for
architectural decisions, and the SIGUSR1 / runtime-attach pattern that
bypasses the app's CDP auth gate.

### Grounding sweep + probe

Separate from the test sweep:
[`runbook.md` "Grounding sweep"](./runbook.md#grounding-sweep) covers
the workflow for verifying case docs themselves against the live
build on every upstream version bump — static anchor pass plus a
runtime probe ([`tools/test-harness/grounding-probe.ts`](../../tools/test-harness/grounding-probe.ts))
that captures IPC handler registry, accelerator state, autoUpdater
gate, AX-tree fingerprint, and other claims static analysis can't
disambiguate. Anchor and drift conventions live in
[`cases/README.md`](./cases/README.md#anchor-scope).

The structure remains automation-friendly for new tests:

1. **Stable test IDs.** `T01`-`T39` and `S01`-`S28` won't move. New tests append. Sequential, not semantic.
2. **Standardized test bodies.** Every functional test has `Severity`, `Steps`, `Expected`, `Diagnostics on failure`, and `References` sections. The Steps and Diagnostics fields are scripted-runner-shaped.
3. **Per-element UI checklists.** Each UI surface file lists interactive elements in a table — every row is a candidate `webContents.executeJavaScript` / `xprop` / DBus assertion.
4. **Severity-driven sweeps.** Tests with a `runner:` field execute via [`tools/test-harness/orchestrator/sweep.sh`](../../tools/test-harness/orchestrator/sweep.sh); JUnit XML lands in `results/results-${ROW}-${DATE}/junit.xml`. Tests without a `runner:` continue to run manually.

For tests that don't have a runner yet, status updates land in [`matrix.md`](./matrix.md) by hand after each manual sweep. For tests that do, the automation invocation is the source of truth — see [`runbook.md`](./runbook.md#automated-runs).

## Conventions

- **One PR per sweep result, not per cell change.** Bundle a full row update into a single commit titled `test: KDE-W sweep $(date +%F)`. Reduces matrix-merge noise.
- **Tested-version pin.** Every status update should mention the `claude-desktop` upstream version + the project version (`v1.3.x+claude...`) in the commit. Otherwise a `✓` from six months ago looks current.
- **Diagnostics on failure are mandatory.** Don't file `✗` without the captures listed in the test's `Diagnostics on failure` block. The runbook covers how to capture each.
- **Issue links go inline.** Status cells link directly to the relevant issue/PR.

See [`runbook.md`](./runbook.md) for the full mechanics.
