# Dossier: asar-path guards in Cowork dispatch

Unit: `patch_asar_path_filter()` + `patch_asar_argv_file_drop_guard()` in
`scripts/patches/cowork.sh` on `main` (lines 28 and 128 at main = `0c4e73f`),
wired from `patch_app_asar()` in `scripts/patches/app-asar.sh` (call sites at
main lines 109 and 114). Both are deleted on the `rebase/official-deb`
working tree (commit `d9cef9e`, 2026-07-02).

## Mechanism

Both functions rewrite the minified main-process bundle
`app.asar.contents/.vite/build/index.js` via node heredocs with dynamic
identifier capture, per the CLAUDE.md minified-JS rules. Source read via
`git show main:scripts/patches/cowork.sh`.

### patch_asar_path_filter (cowork.sh:28)

Targets the directory-check helper (`wFA` in the then-current build). Electron's
ASAR virtual-filesystem shim makes `.asar` archives report
`fs.statSync(path).isDirectory() === true`, so when the repackaged launcher
passed `app.asar` on Electron's argv, the helper classified it as a directory
and the app dispatched it to Cowork as a "folder drop". Header comment
(cowork.sh:12-27) enumerates the symptoms: permission dialog on every launch
(#383), forced Cowork mode (#622), fatal `--add-dir` error in bundled
Claude Code >= 2.1.111 (#632).

Load-bearing anchor regex (function name, parameter, and fs variable all
captured dynamically — none hardcoded):

```
/function\s+([\w$]+)\s*\(\s*([\w$]+)\s*\)\s*\{\s*try\s*\{\s*return\s+([\w$]+)\.statSync\(\s*\2\s*\)\.isDirectory\(\)/
```

Rewrite: `return!PARAM.endsWith(".asar")&&FSVAR.statSync(PARAM).isDirectory()`,
scoped to the matched function so no other `statSync` site can be hit.
Idempotency: coarse `code.includes('.endsWith(".asar")')` check (exits 0 as
already-applied). Anchor miss or failed post-verify is FATAL (`process.exit(1)`
in node, `exit 1` in bash) — a deliberate loud failure citing #383/#622/#632.
Comment notes it runs "independently of the Cowork-mode guard (the function
exists even if Cowork code is absent)". No row for this patch exists in
`scripts/cowork-patch-markers.tsv` (verified against the marker-name list on
main; only `asar-adddir-filter` and `asar-file-drop-guard` are asar rows).

### patch_asar_argv_file_drop_guard (cowork.sh:128)

Targets the second-instance argv file-drop collector (`lKr` in that build),
which has a separate branch `if (!i.startsWith("-") && FSVAR.existsSync(i)) {
A.push(i); }`. The ASAR shim makes `existsSync()` return true for `.asar`
paths, so `app.asar` passed that check and was dispatched to the file-drop
handler (`cCA`), producing a permission prompt on every window close+reopen
(header comment, cowork.sh:104-115; "#383, #622 regression in v2.0.16+").

Two-level idempotency: a bash `grep -qP` for the guard *in context* —
`\.startsWith\("-"\)\s*&&\s*![\w$]+\.endsWith\("\.asar"\)` — deliberately
anchored to `startsWith` "to avoid false-positive matches from other .asar
guards (e.g. the statSync patch or the --add-dir filter)" (cowork.sh:131-135).
Match regex in node:

```
/(![\w$]+\.startsWith\s*\(\s*"-"\s*\)\s*&&\s*)([\w$]+)\.existsSync\(\s*([\w$]+)\s*\)/
```

with an explicit uniqueness assertion (re-greps the escaped full match
globally; >1 match is FATAL) and a whitespace-tolerant post-verify. Injects
`!PARAM.endsWith(".asar")&&` before the `existsSync` call. A threat-model
comment (added later, see revisions) documents why the exact-suffix,
case-sensitive `.asar` match is deliberate: the argv path IS reachable from
user launches (`Exec=... %u` desktop entries), but the only sink is
attach-to-draft (`dispatchOnCoworkFromMain -> selectedFiles`) — no content
read, privilege boundary, or traversal sink — so `toLowerCase()` hardening
was explicitly rejected.

This patch has a verification marker: row `asar-file-drop-guard` in
`scripts/cowork-patch-markers.tsv` (main line 37), consumed by
`scripts/verify-patches.sh`, `tests/verify-patches.bats`, and the CI
static-grep step in `.github/workflows/build-amd64.yml` (issue #559 D6).

## Origin

**Root situation.** All four legacy launchers (deb, rpm, appimage, nix)
appended the `app.asar` path to Electron's argv even though Electron
auto-loads the co-located `resources/app.asar` — so the redundant argument
arrived at the app as a "file to open" (established retrospectively in PR
#700's root-cause analysis). Upstream era: v2.0.x repackages of the Windows
bundle, ~1.9255.2.

**patch_asar_path_filter** — commit `6bfb296d5cf2f66619f1ded2dc55b8d640271533`,
2026-05-24, author aaddrick, subject "fix(patches): reject .asar paths in
directory check to prevent false Cowork dispatch", trailer "Fixes #383, #622,
#632". Merged as PR #640 (merged 2026-05-24T21:00:39Z). Motivating issues:

- #383 (2026-04-06, @awake4real) "app.asar permission." — permission dialog
  on every launch; closed at the exact PR #640 merge timestamp.
- #622 (2026-05-17, @mathys-lopinto) — app starts in "Cowork Mode" on every
  window close+reopen.
- #632 (2026-05-22, @beneshengineering) — app.asar passed as `--add-dir`,
  fatal in bundled claude-code 2.1.111 ("No conversation found" loop).

PR #640's body states the single root cause: the ASAR VFS shim reporting
`isDirectory() === true` for archives, sending app.asar down the Cowork
folder-drop path.

**patch_asar_argv_file_drop_guard** — commit
`623f1b03731a0bfe80660376e6711a5be71120b9`, 2026-05-29, author Mitch
(@MitchSchwartz), merged as PR #669, "Fixes #668". Issue #668 (2026-05-29,
@MitchSchwartz): "app.asar still reaches file drop handler on every cowork
screen focus — incomplete fix after #640/#650 (v2.0.16, KDE, X11)". The
commit body explains the gap: the startup scan excludes the app bundle via a
path-equality check (`tA.resolve(n) !== appPath`), but the second-instance
handler passes argv to `lKr()` with no equivalent guard. Verified against
extracted index.js from v2.0.16 (upstream 1.9255.2); the commit also added the
`asar-file-drop-guard` TSV marker.

## Revision history

Substantive commits touching the two functions on main (from
`git log -L 28,235:scripts/patches/cowork.sh main` plus per-commit diffs):

1. `6bfb296` 2026-05-24 — origin of `patch_asar_path_filter` (PR #640; +94
   lines across cowork.sh and the app-asar.sh call site). See Origin.
2. `623f1b0` 2026-05-29 — origin of `patch_asar_argv_file_drop_guard`
   (PR #669; +113 lines: cowork.sh, app-asar.sh wiring after
   patch_asar_path_filter, TSV marker). See Origin.
3. `5772cc1` 2026-06-04 — "whitespace-tolerant verify + correct threat-model
   comment for #668 guard". Stated cause (commit message): the node match
   regex already tolerated whitespace around `&&`, but the bash idempotency
   grep, the node post-verify regex, and the TSV marker pattern did not, so
   on beautified input they falsely reported "not patched" and verify could
   fail. Added `\s*` around `&&` in all three; dropped a dead
   `cd "$project_root"` before an unconditional `exit 1`; rewrote the
   threat-model note (argv reachable from `Exec=... %u` launches; sink-based
   justification for the exact-suffix match).

Not revisions to this unit, but load-bearing context:

- `ab17b69` (PR #700, @emandel82, merged 2026-06-09) — "stop passing app.asar
  as an Electron arg in all launchers": the root-cause fix for #696 (and
  retroactively #668/#383). The PR body explicitly frames the JS-side guards
  (#640/#650/#669) as patching the receivers while the launcher kept
  injecting the path.
- `a4b8511` 2026-06-09 — restores the explicit app path *only* in the deb/rpm
  global-Electron fallback branch (a PATH-resolved `electron` boots
  default_app, where the positional app path is load-bearing). Main's
  `scripts/packaging/deb.sh:119` sets that path to `.../resources/app.asar`,
  so on main the fallback branch is the one remaining route by which an
  `.asar` argv can exist — the guards stayed in the suite after #700
  (defense-in-depth on the primary path; possibly load-bearing on the
  fallback path — the latter is inference, no commit states it).
- `83ea637` (PR #736, 2026-06-23, yukonSilver re-derive) rewrote much of
  cowork.sh but did not modify either guard function (line-range history
  shows no hits; the TSV asar rows appear only as context lines in its diff).
- `b40441c` (#644) and `2ed0194` hardened identifier regexes elsewhere in
  cowork.sh (spawn guard), not in this unit.

## Related issues and PRs

Direct:

- #383 — issue, CLOSED — "app.asar permission." — motivated
  patch_asar_path_filter; closed by PR #640.
- #622 — issue, CLOSED — "[bug]: Each time i close Claude windows and reopen
  it claude start on 'Cowork Mode'" — motivated; fixed by PR #640.
- #632 — issue, CLOSED — "Local agent mode broken: app.asar passed as
  --add-dir, fatal in bundled claude-code 2.1.111" — motivated; fixed by
  PR #640.
- #640 — PR, MERGED (2026-05-24, @aaddrick) — introduced
  patch_asar_path_filter (commit 6bfb296).
- #668 — issue, CLOSED (@MitchSchwartz) — regression report ("incomplete fix
  after #640/#650") that motivated the argv file-drop guard.
- #669 — PR, MERGED (@MitchSchwartz / commit author "Mitch") — introduced
  patch_asar_argv_file_drop_guard (commit 623f1b0).
- #696 — issue, CLOSED (2026-06-04, @Troijaa) — "File-attach prompt still
  appears on taskbar reopen after v2.0.18 update" — recurrence that exposed
  the launcher argv as the root cause.
- #700 — PR, MERGED (2026-06-09, @emandel82) — "fix: stop passing app.asar as
  an Electron arg" — root-cause launcher fix that removed the guards'
  primary trigger; its body documents why the JS guards "kept regressing".

Sibling guard family (same root cause, different dispatch sites — separate
unit in `scripts/patches/config.sh` on main):

- #649 — issue, CLOSED — "Local agent mode still broken on 2.0.13 — app.asar
  reaches additionalDirectories via packaged-path helper, bypassing #640
  guards" — motivated the config.sh guards.
- #650 — PR, MERGED (2026-05-26) — "filter .asar paths from --add-dir
  dispatch and session restore" (`patch_asar_additional_dirs_guard`,
  `patch_asar_trusted_folder_guard`; `asar-adddir-filter` TSV marker).
- #685 — PR, MERGED — "re-anchor addTrustedFolder .asar guard on method
  declaration" — sibling anchor-rot repair.
- #718 — issue, CLOSED — build failure on upstream 1.12603.1 caused by the
  sibling --add-dir guard's uniqueness assertion (per PR #723's body; the
  issue title mentions the nix build).
- #723 — PR, MERGED — "filter every --add-dir dispatch loop (#718)" —
  sibling fix relaxing the exactly-1 assumption.
- #736 — PR, MERGED (2026-06-24, @pjordanandrsn) — yukonSilver re-derive of
  cowork.sh (sole PR commit 83ea637, authored 2026-06-23; merge commit
  a1fc200, mergedAt 2026-06-24T20:06:48Z); touched the file but not this
  unit (see Revision history).

## Learnings

- `docs/learnings/official-deb-rebase-verification.md` — carries this unit's
  matrix row and the install-layout facts backing the verdict (official
  launcher symlink; see Fate below).
- `docs/learnings/patching-minified-js.md` — the general patch-suite
  playbook; it does not cite #640/#668/#669 directly (grep confirms no
  references), but the techniques this unit exemplifies are all catalogued
  there: idempotency guards, non-unique anchor disambiguation
  (the context-anchored `startsWith("-")` idempotency grep), the uniqueness
  assertion pattern, beautified-input false negatives (exactly the 5772cc1
  bug), and the TSV marker verification layers (doc section "Four layers:
  build log, syntactic validity, asar markers, runtime").

## Fate under the official-deb rebase

Matrix row from `docs/learnings/official-deb-rebase-verification.md`
(working tree, line 26), verbatim:

> | cowork asar-path guards (#383/#622/#632) | **delete** | The
> `statSync().isDirectory()` helpers still exist (3 anchors, no upstream
> `.asar` guard), but the official launcher is a bare ELF symlink — no
> `app.asar` argv ever reaches them. The guards existed only because the
> repackage passed the asar on argv. |

Byte-level evidence behind the row:

- `tools/patch-necessity-audit.sh` `probe_asar_guards()` (lines 214-224)
  counts the `statSync(` try/catch anchors and upstream
  `\.endsWith\("\.asar"\)` occurrences in the official 1.17377.2 `index.js`,
  reporting "official launcher passes no asar argv, so likely not-needed".
- Install-layout fact in the same doc: "`/usr/bin/claude-desktop` is a
  symlink to `../lib/claude-desktop/claude-desktop`" — a bare ELF, no
  wrapper, no argv injection.

How the working tree (rebase branch) handles it now:

- `d9cef9e` ("Phases 1+2 — acquisition swap ... + patch triage", 2026-07-02)
  parked cowork.sh by moving it to `scripts/cowork-fallback/cowork.sh`
  (diffstat: `scripts/{patches => cowork-fallback}/cowork.sh | 302 +------`),
  stripping both asar-guard functions in the move — only `patch_cowork_linux`
  remains (verified at `scripts/cowork-fallback/cowork.sh:14`) — and deleted
  `scripts/cowork-patch-markers.tsv` (-37 lines). The two guard *functions*
  were deleted; the *file* was relocated. Its message lists "cowork/.config
  .asar guards" among the "11 condemned patches deleted".
- `scripts/patches/app-asar.sh` `active_patches=(patch_quick_window
  patch_org_plugins_path)` — the two survivor candidates only; the header
  states the patch-zero contract ("the default verdict for any patch is
  delete, and when the array is empty the official app.asar ships
  byte-identical").
- The new deb launcher generated by `scripts/packaging/deb.sh` (lines
  97-99) execs the official binary directly: "The official Electron binary;
  it auto-loads the co-located resources/app.asar, so no app path is ever
  passed (issue #696)." Identical comments in `rpm.sh:92` and
  `appimage.sh:65`. There is no global-Electron fallback anymore — a missing
  binary is a hard error (`deb.sh:136-140`) — so the one main-branch path
  that still passed an `.asar` argv (a4b8511's fallback) no longer exists.
- `scripts/launcher-common.sh:297-303` records the downstream consequence:
  process fingerprinting "can NOT fingerprint on `app.asar`: since #700 the
  launchers no longer pass it as an argument", so UI-process detection keys
  on `--class=$WM_CLASS` instead.
- The parked Cowork code (`scripts/cowork-fallback/cowork.sh`) retains only
  `patch_cowork_linux`; zero `endsWith(".asar")` matches remain anywhere
  under `scripts/` or `tests/` in the working tree (grep verified).

The verdict is unconditional — this row is not among the doc's "Open items".
Residual risk noted by the matrix itself: the upstream helpers still have no
`.asar` guard of their own, so the symptom family would return only if some
future launcher change reintroduced an `.asar` argv; the guard derivations
survive in main history (6bfb296, 623f1b0) if ever needed.

## Gaps

- Whether the guards were strictly load-bearing on main after PR #700 in the
  deb/rpm global-Electron fallback (which passes
  `.../resources/app.asar` as a positional arg, `main:scripts/packaging/deb.sh:119`)
  is unverified: in default_app mode Electron may consume that positional as
  the app path rather than forwarding it as a file-open. No commit states the
  guards' post-#700 status; "defense-in-depth" is my inference.
- Issue #383's 24-comment thread (2026-04-06 → 2026-05-24) was not read in
  full; any interim workarounds between report and PR #640 are unverified.
- Issue #718's full thread was not read; the sibling-unit linkage rests on
  PR #723's body (its title says "nix build failure" while the PR describes
  an all-format patch-phase failure).
- The rebase verdict rests on static byte evidence (matrix + audit tool);
  no runtime repro of #383/#622/#632 symptoms was attempted against a live
  official install, consistent with the doc's method.
