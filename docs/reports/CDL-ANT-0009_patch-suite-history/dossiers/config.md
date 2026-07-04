# Dossier: Config-write patches (`scripts/patches/config.sh`)

Unit: `patch_config_write_merge` (#400 mcpServers merge),
`patch_asar_trusted_folder_guard` (#400 trusted-folder guard),
`patch_asar_additional_dirs_guard` (#649 additional-dirs guard).
State examined: `main` at `scripts/patches/config.sh` (last touched
5e4f26b); working tree on `rebase/official-deb` (config.sh trimmed at
d9cef9e).

## Mechanism

All three functions operate on
`app.asar.contents/.vite/build/index.js` (CWD set by `patch_app_asar`).
On main they are wired in `main:scripts/patches/app-asar.sh` inside
`patch_app_asar`, invoked in sequence with per-call comments
("Preserve externally-added mcpServers across config writes (#400)",
"Reject .asar paths in addTrustedFolder ... (#400)", "Filter .asar
paths from --add-dir dispatch and session restore ... (#649)").

### 1. `patch_config_write_merge` (main:scripts/patches/config.sh)

- **Idempotency guard:** `grep -q '_cdd_dc'` — the merge snippet's own
  variable name doubles as the marker.
- **Anchor (developer log string, survives minification):** the
  central config-write call site
  `await WRITE_FN(PATH_VAR, CONFIG_VAR), LOGGER.info("Config file written")`.
  Three chained `grep -oP` extractions pull the minified names, e.g.:

  ```
  'await \K[$\w]+(?=\([$\w]+,\s*[$\w]+\)\s*,\s*[$\w]+\.info\("Config file written"\))'
  ```

  using the repo's `[$\w]+` identifier-capture convention (handles
  `$`-prefixed minified identifiers). Extracted `$` chars are escaped
  (`write_fn_re="${write_fn//\$/\\$}"`) before reuse in later patterns.
- **Injection (node -e):** rebuilds the anchor as a RegExp and prepends
  a merge statement before the write:

  ```js
  try{var _cdd_dc=JSON.parse(require("fs").readFileSync(P,"utf8"));
  if(_cdd_dc.mcpServers){C.mcpServers=Object.assign({},_cdd_dc.mcpServers,C.mcpServers||{})}}catch(_cdd_ex){}
  ```

  i.e. re-read the config file from disk on every write; disk
  `mcpServers` are the base, in-memory entries override matching keys —
  so servers added externally (by hand or by MCP installers) survive
  preference writes made from the app's stale in-memory cache.
- **Failure mode:** extraction failures soft-skip (warn + return);
  a found-anchor-but-injection-failed path hard-fails the build
  (`exit 1`).

### 2. `patch_asar_trusted_folder_guard` (main:scripts/patches/config.sh)

- **Idempotency guard:** `grep -qF 'endsWith(".asar"))return'`.
- **Anchor (current, post-2ede75d):** the method declaration itself —
  `async addTrustedFolder(` is not minified and is unique in the
  bundle. Parameter extracted via
  `'async addTrustedFolder\(\K[$\w]+(?=\)\{)'`.
- **Injection:** `if(PARAM.endsWith(".asar"))return;` placed at the
  function-body head (reject on entry). The in-file comment records why
  the anchor moved: "Earlier releases let us anchor on the trailing
  `` ${param}`); `` of the log line, but upstream now folds that log
  call into the comma expression
  ``if(D.info(`…${i}`),await ZOe(i)===null){…}``, so the `);` no longer
  exists."
- **Purpose (per origin commit 364147e):** prevent Electron's ASAR VFS
  shim from letting `app.asar` be recorded as a trusted *folder*, which
  triggered spurious config writes that amplified the #400 stale-cache
  overwrite.
- **Failure mode:** soft-skip on extraction failure, hard-fail
  (`exit 1`) if the injection script errors.

### 3. `patch_asar_additional_dirs_guard` (main:scripts/patches/config.sh)

A node heredoc (`ASAR_ADDDIR_PATCH`) with two sub-patches; the file's
own header comment states the rationale: "PR #640 guards the
directory-check helper and addTrustedFolder IPC handler, but .asar
paths in corrupted pre-#640 sessions survive restore (existsSync passes
via Electron's ASAR VFS shim) and reach additionalDirectories ->
--add-dir -> fatal Claude Code error."

- **Sub-patch 1 — --add-dir dispatch filter (load-bearing):** global
  regex replace of every

  ```
  for\s*\(\s*let\s+([\w$]+)\s+of\s+([\w$]+)\s*\)\s*([\w$]+)\.push\(\s*"--add-dir"\s*,\s*\1\s*\)
  ```

  (plus a `.forEach` fallback variant) into
  `for(let X of Y.filter(_d=>!_d.endsWith(".asar")))Z.push("--add-dir",X)`.
  Idempotent via presence of `.filter(_d=>!_d.endsWith(".asar"))`.
  **FATAL `exit 1`** if zero loops matched and no existing filter —
  "Local agent mode will crash without this patch (#649)."
- **Sub-patch 2 — session-restore self-heal (best-effort):** finds the
  unique string anchor `"Filtering out deleted folder from session"`,
  looks back ≤500 chars for `userSelectedFolders`, and inserts
  `.filter(l=>!l.endsWith(".asar"))` after the `||[])` and before the
  existing `.filter(`. All failure paths here are warn-only
  ("primary --add-dir filter still protects").

## Origin

### #400 pair (merge + trusted-folder guard)

- **Motivating issue:** #400, "claude_desktop_config.json being reset
  continuously", opened 2026-04-14 by @davidcim. Report: every app
  start or mode switch rewrites `~/.config/Claude/claude_desktop_config.json`
  to the same stale content (log line `Config file written`), making it
  impossible to add MCP servers. The pasted `claude-desktop --doctor`
  output records the trigger environment: upstream Claude Desktop
  1.2278.0, repo v1.3.30 (`Installed version: 1.2278.0-1.3.30`),
  Ubuntu 22.04.5 LTS. The pasted config also shows
  `localAgentModeTrustedFolders` containing
  `/usr/lib/claude-desktop/node_modules/electron/dist/resources/app.asar`
  — the .asar-as-trusted-folder symptom the second patch targets.
- **Origin commit:** 364147e (2026-05-24, PR #643, merged
  2026-05-25, author @aaddrick), "fix(patches): preserve mcpServers
  across config writes (#643)". Created `scripts/patches/config.sh`
  with both functions and wired them in `scripts/patches/app-asar.sh`
  and `build.sh`. Commit message diagnosis: "The upstream config writer
  caches parsed config in memory and never re-reads from disk before
  writing. Every preference change ... overwrites the file with the
  stale cache, silently dropping externally-added mcpServers." The
  original trusted-folder guard anchored on the log line
  `` LocalAgentModeSessions.addTrustedFolder: ${PARAM}`); ``
  (`git show 364147e:scripts/patches/config.sh`). Pickaxe confirms no
  earlier ancestry: `-S 'Config file written'` and
  `-S 'addTrustedFolder'` both first hit 364147e — this unit postdates
  the build.sh→modules split (ff4821e), so no cross-file trace needed.

### #649 additional-dirs guard

- **Motivating issue:** #649, opened 2026-05-25 by
  @beneshengineering: "Local agent mode still broken on 2.0.13 —
  app.asar reaches additionalDirectories via packaged-path helper,
  bypassing #640 guards." Follow-up to #632 (same author, closed by
  PR #640 on 2026-05-24). The issue confirmed both existing guards
  present in the installed asar (the cowork directory-check from #640
  and the addTrustedFolder guard from #643) yet the runtime still
  forwarded the asar as `--add-dir`, fatally rejected by bundled
  Claude Code ≥ 2.1.111 ("No conversation found" loop).
- **Origin commit:** 4451694 (2026-05-26, PR #650, author @aaddrick),
  "fix(patches): filter .asar paths from --add-dir dispatch and session
  restore (#650)". Rationale from the commit message: corrupted
  pre-#640 sessions survive restore, so filter at (1) the --add-dir
  dispatch loop, "single convergence point for ALL code paths that feed
  additionalDirectories", and (2) session restore, which "self-heals
  corrupted persisted state so the primary filter doesn't fire
  indefinitely."

## Revision history

1. **364147e** — 2026-05-24 (PR #643). Unit created:
   `patch_config_write_merge` + `patch_asar_trusted_folder_guard`.
   Fixes #400 (issue auto-closed at merge, 2026-05-25). Included a
   style follow-up squashed into the same commit ("consolidate local
   declarations in config.sh").
2. **4451694** — 2026-05-26 (PR #650). Added
   `patch_asar_additional_dirs_guard` (two sub-patches). Fixes #649.
   Also registered markers in `scripts/cowork-patch-markers.tsv` and
   updated `tests/verify-patches.bats`.
3. **2ede75d** — 2026-06-04 (PR #685, author @maplefater; git author
   name "luosihao"). Re-anchored the trusted-folder guard on the method
   declaration. Cause per commit/PR: the build hard-failed on upstream
   Claude Desktop 1.10628.0 with "addTrustedFolder anchor not found"
   because re-minification folded the log statement into the comma
   expression ``if(D.info(`...${i}`),await ZOe(i)===null){...}`` — the
   old anchor's trailing `);` became `),`. A competing fix, PR #674
   (@mhentschke, same approach, described the move as happening between
   1.9255.x and 1.9659.2), was closed un-merged two minutes after #685
   merged. (Changelog-only commits 0b281eb and 53dfe4a, which credit
   @maplefater, are excluded as non-substantive.)
4. **5e4f26b** — 2026-06-16 (PR #723, author @typedrat / "Alexis
   Williams"; merge commit e8b9bfc). Rewrote sub-patch 1 from
   "exactly one match or FATAL" to a global replace over both for-of
   and forEach variants with a filtered-loop count. Cause per commit
   message: upstream 1.12603.1 ships **two** identical
   `for(let O of A)Y.push("--add-dir",O)` dispatch loops, so the #650
   single-match assertion aborted every build format (issue #718,
   "nix build failure on d2ce046", by @fdnt7). The fail-loud invariant
   was reframed as "every unfiltered --add-dir dispatch must filter
   .asar paths". Added `tests/config-patches.bats` (one test:
   "additional dirs guard filters every --add-dir dispatch loop").
   A competing PR #722 (@marveon, "handle SDK bundled twice in
   1.12603.1") was closed 2026-06-16 with a maintainer comment
   endorsing its diagnosis ("1.12603.1 bundles the Claude Code SDK
   per-panel now, so the --add-dir dispatch loop shows up twice").

Adjacent context (not a revision of this file): commit ab17b69
(2026-06-09), "fix: stop passing app.asar as an Electron arg in all
launchers", removed the redundant asar argv from all four launchers and
its message identifies that argv as "the root cause behind the
recurring prompt the renderer-side .asar filters" — explicitly naming
#650 among them — "kept missing". This is the first on-main statement
of the no-asar-argv reasoning that later condemns the guards in the
rebase matrix.

## Related issues and PRs

| Ref | Kind | Title | State | Role |
|---|---|---|---|---|
| #400 | issue | claude_desktop_config.json being reset continuously | closed | Motivated the merge patch and the trusted-folder guard; closed by PR #643 |
| #643 | PR | fix(patches): preserve mcpServers across config writes | merged 2026-05-25 | Introduced the unit (commit 364147e) |
| #632 | issue | Local agent mode broken: app.asar passed as --add-dir, fatal in bundled claude-code 2.1.111 | closed 2026-05-24 | Predecessor report; closed by PR #640, whose guards #649 showed insufficient |
| #640 | PR | fix(patches): reject .asar paths in directory check to prevent false Cowork dispatch | merged 2026-05-24 | Sibling guard (cowork.sh, separate unit) whose insufficiency motivated the additional-dirs guard |
| #649 | issue | Local agent mode still broken on 2.0.13 — app.asar reaches additionalDirectories ... bypassing #640 guards | closed 2026-05-26 | Motivated `patch_asar_additional_dirs_guard`; closed by PR #650 |
| #650 | PR | fix(patches): filter .asar paths from --add-dir dispatch and session restore | merged 2026-05-26 | Added the additional-dirs guard (commit 4451694) |
| #674 | PR | fix(patches): anchor addTrustedFolder guard on function definition | closed un-merged 2026-06-04 | Competing anchor fix, superseded by #685 (inference from closure 2 min after #685 merged; identical approach) |
| #685 | PR | fix(config): re-anchor addTrustedFolder .asar guard on method declaration | merged 2026-06-04 | Fixed the build-breaking anchor rot on upstream 1.10628.0 (commit 2ede75d) |
| #718 | issue | [bug]: nix build failure on d2ce046 | closed 2026-06-16 | Regression report: #650's single-match assertion FATALed on upstream 1.12603.1's duplicate dispatch loops |
| #722 | PR | fix(config): patch --add-dir filter to handle SDK bundled twice in 1.12603.1 | closed un-merged 2026-06-16 | Competing fix for #718; diagnosis credited in maintainer comment, superseded by #723 |
| #723 | PR | fix(patches): filter every --add-dir dispatch loop (#718) | merged 2026-06-16 | Fixed #718 (commit 5e4f26b, merge e8b9bfc) |

GitHub keyword searches for additional reports ("mcpServers config
reset", "claude_desktop_config") returned no issues beyond the above.

## Learnings

- **`docs/learnings/official-deb-rebase-verification.md`** — the
  unit's authoritative fate record: two matrix rows (quoted below), the
  patch-zero tally counting this unit's "1 behavioral check", and the
  Open item "Reproduce config #400 against a live official install
  (behavioral)."
- **`docs/learnings/patching-minified-js.md`** — does not cite
  config.sh directly (verified by grep), but documents the conventions
  this unit exhibits: the `[$\w]+` identifier-capture convention for
  `$`-prefixed minified names (config.sh's extraction greps use exactly
  this class), literal-string anchor selection ("Config file written",
  `async addTrustedFolder(`), and idempotency-guard patterns.

## Fate under the official-deb rebase

Matrix rows, verbatim from
`docs/learnings/official-deb-rebase-verification.md` (verified against
official 1.17377.2, audited 2026-07-02):

> | `config.sh` #649 trusted-folder guards | **delete** | `addTrustedFolder(o)` present without a `.asar` guard, but same reasoning as above: no on-disk `.asar` argv path exists on Linux. |
>
> | `config.sh` #400 mcpServers merge | **verify behaviorally** | The `Config file written` write anchor is intact, so the config writer is structurally unchanged. Reproduce #400 against a live official install before deciding; file upstream either way. |

("same reasoning as above" refers to the cowork asar-path guards row:
"the official launcher is a bare ELF symlink — no `app.asar` argv ever
reaches them. The guards existed only because the repackage passed the
asar on argv.") The rows are reproducible with
`tools/patch-necessity-audit.sh` (present on the branch; lines 227–251
check the `Config file written` anchor and grep
`async addTrustedFolder\(\K[$\w]+(?=\)\{)` plus the absence of any
upstream `.asar` guard within the method).

How the working tree (rebase/official-deb) handles it, all changed in
d9cef9e (2026-07-02, "feat(rebase): Phases 1+2"):

- **Both .asar guards deleted.** `scripts/patches/config.sh` shrank
  from 296 to 104 lines (`git diff main..rebase/official-deb --stat`:
  13 insertions, 205 deletions); only `patch_config_write_merge`
  remains. The file header states: "The former .asar guards
  (addTrustedFolder, --add-dir dispatch, session restore) were deleted
  with the rebase: the official launcher is a bare ELF symlink, so no
  on-disk .asar path ever reaches argv on Linux."
- **The merge patch is kept but UNWIRED.** The
  `active_patches` array in `scripts/patches/app-asar.sh` is
  `(patch_quick_window patch_org_plugins_path)` — no config function.
  The config.sh header says it re-earns its slot only after #400 "must
  be reproduced against a live official install", "and it gets filed
  upstream either way"; d9cef9e's commit message matches: "config.sh
  trimmed to the #400 mcpServers merge, kept unwired pending a
  behavioral repro against a live official install."
- **Test coverage removed with the guard.** `tests/config-patches.bats`
  (its single test targeted the additional-dirs guard) does not exist
  on the branch (`tests/` contains only doctor/launcher bats and
  artifact scripts), consistent with d9cef9e's "Tests keyed to deleted
  patches removed." The surviving merge patch has no bats coverage on
  either branch.
- Nothing in `scripts/setup/official-deb.sh`, `scripts/doctor.sh`, or
  `scripts/launcher-common.sh` substitutes for this unit — the deletion
  is justified by absence of the triggering input (no asar argv), not
  by a replacement mechanism; the merge patch's fate is deferred, not
  decided.

**Open verification item (conditional verdict):** the doc's Open items
list carries "Reproduce config #400 against a live official install
(behavioral)." Until that repro runs, the mcpServers merge is neither
condemned nor a survivor.

## Gaps

- **#400's trigger version IS recorded in the issue.** The pasted
  `claude-desktop --doctor` output in the issue body includes
  `[PASS] Installed version: 1.2278.0-1.3.30` — upstream Claude
  Desktop 1.2278.0 packaged as repo v1.3.30, on Ubuntu 22.04.5 LTS
  (`lsb_release -d` in the same body). The residual gap is narrower:
  commit 364147e (~6 weeks later) does not restate which upstream
  version the fix was developed against, and the issue's full comment
  thread remains unread.
- **Whether #400 reproduces on the official 1.17377.2 build is
  unknown** — that is precisely the open behavioral check; the anchor
  being byte-intact shows structural continuity of the writer, not that
  the stale-cache bug persists.
- **PR #674 vs #685 supersession** is inferred from timing (closed two
  minutes after #685 merged, same approach) — I did not read a comment
  explicitly closing #674 as duplicate.
- **@maplefater ↔ "luosihao" identity**: PR #685 (GitHub author
  @maplefater) merged as commit 2ede75d (git author "luosihao");
  the changelog commit 53dfe4a credits @maplefater for the same fix, so
  they appear to be the same contributor, but I did not confirm the
  account mapping.
- No upstream (anthropics) issue filing for the #400 config-writer
  behavior was located in this repo's records; the matrix says "file
  upstream either way", and I found no evidence it has been filed yet.
