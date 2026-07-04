# Dossier: Shared patch machinery and asar repack scaffolding

Unit: `scripts/patches/_common.sh` (`extract_electron_variable`,
`fix_native_theme_references`), `scripts/patches/app-asar.sh`
orchestration (package.json `main`/`desktopName` edits, productName vs
`WM_CLASS` fail-fast, i18n JSON copy, tray-icon copy into the asar),
and the asar extract/repack scaffolding (`finalize_app_asar` in
`scripts/staging/electron.sh`, `copy_locale_files` in
`scripts/staging/locales.sh`).

This is not a behavior patch. It is the chassis every behavior patch
runs on: unpack the upstream asar, normalize identifiers that upstream
re-minifies between releases, copy resources the Windows-extracted tree
kept in the wrong place, then repack.

## Mechanism (state on `main`)

All paths below are `main` unless stated. Read via
`git show main:<path>`.

### Dynamic identifier extraction — `scripts/patches/_common.sh`

`extract_electron_variable()` greps the minified bundle
`app.asar.contents/.vite/build/index.js` for the electron module
variable, because the name changes every upstream re-minification:

```bash
electron_var=$(grep -oP '[$\w]+(?=\s*=\s*require\("electron"\))' \
	"$index_js" | head -1)
```

with a fallback anchor on the Tray constructor,
`grep -oP '(?<=new )[$\w]+(?=\.Tray\b)'`, and a hard `exit 1` if both
fail. It exports two globals for downstream patches: `electron_var`
(literal) and `electron_var_re` (`${electron_var//\$/\\$}`,
regex-escaped for sed), so `$`-containing names like `$e` survive both
grep and sed contexts.

`fix_native_theme_references()` collects every `[$\w]+(?=\.nativeTheme)`
identifier that is not `electron_var` and seds it to `electron_var` —
an auto-repair for a recurring upstream minifier bug where the bundle
references `nativeTheme` through the wrong alias (see #218). It is
idempotent by construction (after one pass there are no wrong refs
left; `grep -Fxv "$electron_var"` plus `|| true` makes the empty case a
no-op).

### Orchestration — `scripts/patches/app-asar.sh` (`patch_app_asar`)

Per the file header: "Top-level app.asar patch orchestration: extract,
wrap entry point, stub native module, copy i18n and tray icons, then
invoke per-feature patches." Concretely:

1. Copies `app.asar` + `app.asar.unpacked` out of the **Windows**
   extraction layout `$claude_extract_dir/lib/net45/resources/` and runs
   `"$asar_exec" extract app.asar app.asar.contents`.
2. **package.json `main` edit**: reads the original `main`, writes
   `frame-fix-entry.js` (a two-line `require('./frame-fix-wrapper.js')`
   + `require original main` shim), and via `node -e` sets
   `pkg.originalMain`, `pkg.main = 'frame-fix-entry.js'`,
   `pkg.desktopName`, and `pkg.optionalDependencies['node-pty']`.
   The in-file comment records the design: "BrowserWindow
   frame/titleBarStyle patching is handled at runtime by
   frame-fix-wrapper.js via a Proxy on require('electron'). No sed
   patches needed".
3. **`desktopName`** is `claude-desktop.desktop`, or
   `io.github.aaddrick.claude-desktop-debian.desktop` when
   `build_format == 'appimage'` — Electron derives the Wayland `app_id`
   from this field (taskbar grouping on KDE Wayland, #561/#562).
4. **productName vs WM_CLASS fail-fast**: aborts the build if upstream
   renames the product, because Electron ignores `--class=` and derives
   X11 WM_CLASS from `productName`:

   ```bash
   if [[ $product_name != "$WM_CLASS" ]]; then
   	echo "Error: upstream productName '$product_name' != WM_CLASS" ...
   	exit 1
   fi
   ```

   `WM_CLASS` is the single source of truth, `readonly WM_CLASS='Claude'`
   at `main:build.sh:39`.
5. **i18n copy**: `cp "$claude_extract_dir/lib/net45/resources/"*-*.json
   app.asar.contents/resources/i18n/` — the Windows nupkg keeps the
   locale JSONs beside the asar, but the app resolves
   `resources/i18n/en-US.json` inside it (#23).
6. **Tray-icon copy into the asar**:
   `cp .../resources/Tray* app.asar.contents/resources/` with the
   comment "so both packaged (process.resourcesPath) and unpackaged
   (app.getAppPath()) code paths can find them" — the unpackaged path is
   the Nix build, where `isPackaged=false` (573f052).
7. Then serially invokes the whole per-feature patch suite
   (tray, quick-window, claude-code, cowork, wco-shim, config guards,
   org-plugins — ~17 functions), each sourced from its own
   `scripts/patches/*.sh` module.

### Repack scaffolding — `scripts/staging/electron.sh` and `locales.sh`

`finalize_app_asar()` repacks with
`"$asar_exec" pack app.asar.contents app.asar --unpack '**/*.node'`;
the comment records why `--unpack` is load-bearing: "Electron's
asar->.unpacked redirect requires the manifest entry to exist;
otherwise loaders that require() files from inside the asar get
MODULE_NOT_FOUND." It then re-seeds `app.asar.unpacked` with the native
stub, `cowork-vm-service.js`, and node-pty binaries.
`copy_locale_files()` (`scripts/staging/locales.sh`) duplicates the
`*-*.json` locale copy into the Electron resources dir for the
packaged-path lookup.

## Origin

The unit accreted in five waves; every wave was forced by the
fundamental mismatch of running a Windows-extracted asar on Linux, or
by upstream re-minification.

- **Extract/copy/repack scaffolding + tray-icon copy**: commit
  `d8f4bbe`, 2024-12-26, the repository's initial commit
  (`build-deb.sh`). It already contained `npx asar extract`,
  `cp ../lib/net45/resources/Tray* app.asar.contents/resources/`, and
  `npx asar pack app.asar.contents app.asar` — the scaffolding is as
  old as the project. (The in-asar tray copy was not continuous:
  `47c1889` removed it 2025-11-07 in favor of a filesystem copy, and
  `573f052` restored it 2026-02-26 for Nix — see revision history.)
- **i18n copy**: issue #23 ("[Bug] resources/i18n/en-US.json not
  found in /usr/lib/claude-desktop/app.asar", 2025-03-04, Coldsewoo).
  The documented fix is PR #25 "Fix: copy i18n json files before
  build" (commit `ee7e4bc`, authored 2025-03-04 by Coldsewoo, the
  issue author; merged 2025-03-29), copying `*.json`. Commit
  `466705d` (2025-03-07, Stany MARCEL, PR #26 "Update to 0.8.0")
  landed first with the surviving `*-*.json` glob — functionally the
  same copy, but its link to #23 is an **inference from the identical
  code change**, not a recorded reference: PR #26's body is empty,
  its commit message says only "Update to 0.8.0", and issue #23's
  timeline cross-references only #25/#14/#31
  (`gh api .../issues/23/timeline`). Both are in `main` history; the
  `*-*.json` form won.
- **package.json `main` edit**: commit `7882635`, 2025-11-04,
  speleoalex, PR #127 "feat: Add native window decorations support for
  Linux" — introduced `frame-fix-entry.js` and the
  `pkg.originalMain`/`pkg.main` rewrite, because Claude Desktop windows
  "appeared without borders or native decorations on Linux window
  managers" (commit message).
- **Dynamic identifier extraction**: commit `7bd2f38`, 2026-02-08,
  PR #220 "fix: use regex extraction for electron variable in tray
  patches", fixing #218 and #219. Upstream v1.1.2321 re-minified the
  electron variable `oe` → `Ae`, breaking every hardcoded tray sed;
  #218 also reported the upstream minifier bug (wrong alias on
  `nativeTheme`) that `fix_native_theme_references` auto-repairs.
  Commit message: "The variable name changes between releases due to
  minification."
- **WM_CLASS fail-fast**: commit `e7e6475`, merged as `73c9b8f`,
  2026-05-27, PR #655 (details under Revision history).

## Revision history

Substantive changes in date order (formatting/lint-only commits such as
`7917ea4` "style: trim comments per simplifier review" skipped):

1. `d8f4bbe` 2024-12-26 — initial commit; asar extract/pack scaffolding
   and tray-icon copy in `build-deb.sh`.
2. `466705d` 2025-03-07 (PR #26) and `ee7e4bc` merged 2025-03-29
   (PR #25) — i18n locale JSON copy into
   `app.asar.contents/resources/i18n/`; cause: issue #23, app fails to
   find `resources/i18n/en-US.json` inside the asar (the #23 link is
   recorded for #25; for #26 it is inferred from the identical code —
   see Origin).
3. `7882635` 2025-11-04 (PR #127) — package.json `main` redirected
   through `frame-fix-entry.js`; cause stated in commit: frameless
   windows on Linux WMs.
4. `47c1889` 2025-11-07 (fixes #122 "is there a way to display the
   tray icon", closed) — **removed** the `d8f4bbe` in-asar tray copy
   (deleted `cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/Tray"*
   app.asar.contents/resources/`) and copied `Tray*` into the
   Electron resources dir instead: "Tray icons must be in filesystem
   (not inside asar) for Electron Tray API to access them" (in-diff
   comment). This is the alongside-only state `573f052` later
   reversed for Nix.
5. `3591392` 2026-01-05 ("Add node-pty support for Claude Code
   terminal integration") — added
   `pkg.optionalDependencies['node-pty'] = '^1.0.0'` to the
   package.json edit (Mechanism item 2) and first staged node-pty
   files into the asar/unpacked tree.
6. `7bd2f38` 2026-02-08 (PR #220, fixes #218/#219) — hardcoded `oe`
   replaced by dynamic extraction from the `require("electron")`
   anchor + `new X.Tray` fallback; added `fix_native_theme_references`
   and the fail-fast on extraction failure. Cause: upstream
   re-minification in v1.1.2321.
7. `4043474` 2026-02-08 — refactor: the inline logic became named
   helpers `extract_electron_variable()` /
   `fix_native_theme_references()` with `mapfile` array-safe iteration
   (commit message states this is extraction/readability only).
8. `546f845` 2026-02-24 (PR #253, fixes #252) — `$`-prefixed
   identifier support. Upstream v1.1.4088 minified the electron var to
   `$e`; `\w` doesn't match `$`, so extraction captured `e` and
   downstream seds inserted code mid-name, producing
   "`$let _trayStartTime` which is a SyntaxError" (commit message).
   Introduced `electron_var_re` for regex-escaped sed usage.
9. `573f052` 2026-02-26 (merged in PR #266, the NixOS flake) — tray
   icons copied **into** the asar: "Previously, tray icons were only
   copied alongside the asar ... so unpackaged builds (like Nix, where
   isPackaged=false) couldn't find them" (commit message) — reversing
   the `47c1889` state.
10. `3150477` 2026-04-17 (carried in PR #421 "fix: cowork existsSync
    crash on 1.3109+ and unblock node-pty terminal", merged
    2026-04-17) — added `--unpack '**/*.node'` to `asar pack` in
    `finalize_app_asar` and staged node-pty `build/` into the asar.
    The commit message records the manifest-entry requirement the
    Mechanism section quotes: "Electron's asar -> .unpacked redirect
    never fires because the redirect requires a manifest entry
    annotated as unpacked. The require returns MODULE_NOT_FOUND".
11. `ff4821e` 2026-04-20 — the 2124-line `build.sh` split into
    modules; this created `scripts/patches/_common.sh`
    ("extract_electron_variable etc." per the commit message),
    `scripts/patches/app-asar.sh`, `scripts/staging/electron.sh`, and
    `scripts/staging/locales.sh`. Pure move, function bodies verbatim.
12. `5a98854` 2026-05-03 (PR #562, jslatten, fixes #561) — added the
    `pkg.desktopName` edit (with the AppImage-specific ID) so KDE
    Wayland groups the pinned launcher and the running window
    ("set desktopName for Wayland grouping").
13. `b40441c` 2026-05-24 (PR #644) — regex hardening audit: "Replace
    `\$?\w+` with `[$\w]+` in _common.sh (3 sites) — the old pattern
    silently truncated mid-$ names like `i$A`" (commit message).
14. `76a5a21` 2026-05-25 (PR #648, fixes #647) — aligned WM_CLASS and
    StartupWMClass to `claude-desktop` across all formats. Superseded
    two days later: the direction was wrong because Electron ignores
    `--class=`.
15. `e7e6475` / merge `73c9b8f` 2026-05-27 (PR #655, fixes #652, ref
    #647/#561 and discussion #653) — reversal and centralization:
    "Electron ignores --class= and derives WM_CLASS from productName in
    package.json ('Claude') ... users confirmed via /proc cmdline +
    xprop that the flag is silently ignored" (commit message). Added
    `readonly WM_CLASS='Claude'` in `build.sh` and the build-time
    productName assertion in `app-asar.sh` — the fail-fast this unit
    still carries. "Down from 6 independent hardcoded values to 1
    definition + 1 derivation."

Later commits touching `app-asar.sh` (`cf2b0fc` #515, `5c8191e` #538,
`337e9a4`/`6bfb296` PR #639, `364147e` #643, `4451694` #650, `623f1b0`
#668) only added or swapped per-feature patch invocations in the
orchestrator; the substance of those belongs to their own units.

## Related issues and PRs

| Ref | Kind | Title | State | Role |
|---|---|---|---|---|
| #23 | issue | [Bug] resources/i18n/en-US.json not found in /usr/lib/claude-desktop/app.asar | closed | motivated the i18n copy |
| #25 | PR | Fix: copy i18n json files before build | merged 2025-03-29 | i18n copy (Coldsewoo variant) |
| #26 | PR | Update to 0.8.0 | merged 2025-03-07 | landed the surviving `*-*.json` i18n copy (#23 link inferred from code identity, not recorded) |
| #122 | issue | is there a way to display the tray icon | closed | motivated `47c1889` (tray icons moved out of the asar) |
| #127 | PR | feat: Add native window decorations support for Linux | merged 2025-11-05 | origin of the package.json `main` rewrite |
| #218 | issue | Tray icon missing — Anthropic's app.asar has oe/Ae minifier bug + menuBarEnabled config reset on update | closed | motivated dynamic extraction + nativeTheme auto-repair |
| #219 | issue | Tray icon patch uses wrong variable name (oe vs Ae) in v1.1.2321 | closed | duplicate report of the same breakage |
| #220 | PR | fix: use regex extraction for electron variable in tray patches | merged 2026-02-08 | created `extract_electron_variable` |
| #252 | issue | SyntaxError on launch: Stray `$` in `index.js` breaks v1.3.12+claude1.1.4088 | closed | regression the `\w`-vs-`$` trap caused |
| #253 | PR | fix: support $-prefixed electron variable names in build patches | merged 2026-02-24 | fixed #252; introduced `electron_var_re` |
| #266 | PR | feat: add NixOS flake with build.sh integration | merged 2026-03-01 | carried 573f052 (tray icons into the asar) |
| #421 | PR | fix: cowork existsSync crash on 1.3109+ and unblock node-pty terminal | merged 2026-04-17 | carried 3150477 (`--unpack '**/*.node'` + manifest rationale) |
| #561 | issue | KDE Wayland: pinned Claude launcher opens a separate generic Electron taskbar entry | closed | motivated the `desktopName` edit |
| #562 | PR | Set desktopName for Wayland grouping | merged 2026-05-03 | added the `desktopName` edit |
| #644 | PR | fix(patches): harden regex patterns for minified JS identifiers | merged 2026-05-25 | hardened `_common.sh` regexes (3 sites) |
| #647 | issue | [bug]: Arch .desktop incorrect StartupWMClass | closed | first WM_CLASS mismatch report |
| #648 | PR | fix: align WM_CLASS and StartupWMClass to claude-desktop across all formats | merged 2026-05-25 | wrong-direction fix, superseded by #655 |
| #652 | issue | [bug]: .deb StartupWMClass=claude-desktop doesn't match window's WM_CLASS, creates duplicate gear icon in GNOME dock | closed | regression #648 caused; motivated the fail-fast |
| #655 | PR | fix: centralize StartupWMClass=Claude to match upstream productName | merged 2026-05-27 | added the productName/WM_CLASS fail-fast |

Discussion #653 is referenced by the #655 commit message as
supporting analysis (GitHub discussion, not an issue/PR).

## Learnings

- `docs/learnings/patching-minified-js.md` — the unit's operating
  manual, distilled from its own failures: "Capturing identifiers:
  `\w` doesn't match `$` ... Three recurrences (PRs #253, #421, #555)
  before the convention stuck. Use `[$\w]+`." Also covers anchor
  selection (literals over identifiers), idempotency guards, and the
  SHA-256-pinned hypothesis-verification recipe. The rebase tracking
  plan (`.tmp/plans/official-deb-rebase-tracking.md`, lines 28-29 and
  211-212) rules the doc "APPLICABLE, not historical" (verdict
  softened 2026-07-02, aaddrick concurring): "the methodology governs
  the survivor patch suite". That verdict lives in the tracking plan,
  not in the doc itself or anywhere under `docs/`.
- `docs/learnings/official-deb-rebase-verification.md` — records the
  install-layout facts that decide this unit's fate (see below),
  including the `productName is Claude` invariant and the per-arch
  dependency contract.
- `docs/learnings/nix.md` — context for revision 7 (573f052):
  Electron resource path resolution and `isPackaged=false` on Nix,
  which is why tray icons had to live inside the asar.

## Fate under the official-deb rebase

There is no single matrix row for the machinery itself — it is the
chassis the matrix rows ran on. The matrix outcome that determines its
fate is the aggregate: "Patch-zero score: 11 delete, 2 survivor
candidates (≤2 budget holds), 1 behavioral check, 1 parked subsystem"
(`docs/learnings/official-deb-rebase-verification.md`). With 11 of the
patches deleted, most of the chassis has nothing left to carry.
Commit `d9cef9e` ("feat(rebase): Phases 1+2 — acquisition swap to the
official .deb + patch triage", 2026-07-02) deletes
`scripts/patches/_common.sh` (-56 lines), `tray.sh`,
`claude-code.sh`, `wco-shim.sh`, and
`scripts/staging/{electron,locales,icons}.sh`, rewrites
`app-asar.sh`, and PARKS `cowork.sh` unwired under
`scripts/cowork-fallback/` — a move plus 302-line trim (diffstat:
`scripts/{patches => cowork-fallback}/cowork.sh | 302 +------`),
"for the 3.1 cowork-bwrapd investigation" (commit message). That is
the matrix's "1 parked subsystem"; `scripts/cowork-fallback/cowork.sh`
is present on the working tree.

Per-piece verdicts and evidence:

- **`extract_electron_variable` / `fix_native_theme_references` —
  deleted.** No surviving patch consumes `electron_var`: on the
  working tree, `grep -rn electron_var scripts/` returns nothing. Both
  survivor candidates are self-anchored — `quick-window.sh` extracts
  its own variable from the unique
  `setAlwaysOnTop(!0,"pop-up-menu")` literal, and `org-plugins.sh`
  anchors on the literal `Application Support/Claude/org-plugins`.
  The extraction *discipline* survives in those files even though the
  shared helper is gone.
- **package.json `main` edit (frame-fix) — deleted.** Matrix row:
  "`frame-fix-wrapper.js` | **delete** | The only `frame:!1` sites are
  the Quick Entry popup and two transparent overlay windows —
  intentionally frameless on every platform. The main window omits
  `frame` (system frame)." No `frame-fix` reference remains anywhere
  under `scripts/` on the branch; the official entry point stays
  `.vite/build/index.pre.js` (teardown report,
  `.tmp/reports/linux-official-teardown/claude-desktop-linux-teardown.tex`).
- **`desktopName` edit — deleted.** No `desktopName` reference remains
  in the working tree's `scripts/` or `build.sh`. The official `.deb`
  ships its own `.desktop` file and packaged tree; our packaging keeps
  `StartupWMClass=Claude` (`build.sh:141` on the branch). Note the doc
  flags an upstream quirk to watch: "the official `.desktop` sets
  `StartupWMClass=claude-desktop`, which mismatches the
  productName-derived WM class — check at runtime."
- **productName vs WM_CLASS fail-fast — SURVIVES, upgraded.** Doc:
  "**`productName` is `Claude`** (`app.asar` `package.json`), so the
  `WM_CLASS='Claude'` invariant and `~/.config/Claude` survive the
  rebase." On the working tree the guard runs unconditionally in
  `scripts/patches/app-asar.sh` via a new `_asar_package_json_field`
  helper that uses `asar extract-file` to read `productName` without a
  full extract — so the assertion holds even on a patch-zero build
  that never unpacks the asar. `readonly WM_CLASS='Claude'` persists
  at `build.sh:36`.
- **i18n and tray-icon copies — deleted.** The premise (Windows nupkg
  layout with resources beside the asar, plus Nix `isPackaged=false`
  quirks) is gone: the official `.deb` is a conventional electron-forge
  Linux tree, and the teardown inventories "purpose-made Linux tray
  icons" `TrayIconLinux(-Dark).png` shipped in `resources/`
  (teardown .tex, artifact table + tray section). Matrix row for the
  adjacent tray patch: "The Linux `png` branch natively selects
  `TrayIconLinux(-Dark).png` (GNOME or dark theme → Dark)." No `i18n`
  or `Tray` copy code remains in the working tree's `scripts/`.
- **Asar extract/repack scaffolding — SURVIVES conditionally, rebuilt.**
  Working-tree `scripts/patches/app-asar.sh` is now a thin orchestrator
  with `active_patches=(patch_quick_window patch_org_plugins_path)`.
  Its header states the contract: "the patch-zero contract: the default
  verdict for any patch is delete, and when the array is empty the
  official app.asar ships byte-identical (no extract, no repack)."
  When patches are active, the repack "preserv[es] upstream's unpacked
  set exactly": the `--unpack` expression is derived from the shipped
  `app.asar.unpacked` tree via `find`, folded into a single brace glob
  (`asar pack` honors only one `--unpack` expression), and followed by
  an equality check that hard-fails if the repacked unpacked set
  diverges ("a native helper got inlined (or dropped) and would fail
  at runtime"). `build.sh` calls it as "Phase 3: Conditional patch
  stage (patch-zero when active_patches is empty)".

Open verification items relevant to this unit's survivors (doc,
"Open items"): the Quick Entry stale-focus repro on KDE Plasma decides
whether `patch_quick_window` stays in `active_patches`; if both
survivors fall, the orchestrator's steady state is the byte-identical
patch-zero path and the repack scaffolding becomes dormant code.

## Gaps

- **No byte-level evidence for the i18n deletion specifically.** The
  verification doc and teardown confirm the official tray icons and
  packaged layout, but I found no line in either explicitly confirming
  the locale JSONs sit at `resources/i18n/` *inside* the official
  `app.asar`. The deletion rests on the official artifact being
  upstream-tested as shipped (inference), not on an audited byte check
  like the other rows. No extracted official tree was present in the
  workspace to check directly, and `tools/patch-necessity-audit.sh`
  has no i18n probe.
- The exact merge vehicle for `4043474` (helper-extraction refactor)
  was not looked up on GitHub; it may have been part of PR #220's
  branch (both dated 2026-02-08). Not material to the story.
- Discussion #653 was cited from the #655 commit message; its content
  was not fetched.
- PR #555 is cited only via `patching-minified-js.md` as a later
  recurrence of the `$`-identifier trap in another unit (cowork); it
  was not independently verified here. PR #421 — named in the same
  doc for its cowork commit — additionally carried `3150477`, a
  direct change to this unit's repack scaffolding (revision 10); its
  cowork half still belongs to the cowork unit.
