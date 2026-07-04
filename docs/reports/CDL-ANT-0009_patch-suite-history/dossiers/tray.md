# Dossier: Tray patches + fix_native_theme_references

Unit: `scripts/patches/tray.sh` (`patch_tray_menu_handler`,
`patch_tray_icon_selection`, `patch_tray_inplace_update`) and
`scripts/patches/_common.sh` (`extract_electron_variable`,
`fix_native_theme_references`) — as they exist on `main`. The fourth
function in `tray.sh`, `patch_menu_bar_default`, shares the file but is a
separate matrix row ("menuBarEnabled default") and is only referenced here
where its history is entangled with the tray functions.

All main-state code read via `git show main:scripts/patches/tray.sh` and
`git show main:scripts/patches/_common.sh`.

## Mechanism

All five functions operate on the minified main-process bundle
`app.asar.contents/.vite/build/index.js`.

### `extract_electron_variable` (_common.sh)

Resolves the minified name of the `electron` module binding and exports it
as globals `electron_var` / `electron_var_re` (with `$` escaped for
PCRE/sed use) consumed by the tray and quick-window patches:

- Primary anchor: `grep -oP '[$\w]+(?=\s*=\s*require\("electron"\))'`
- Fallback anchor: `grep -oP '(?<=new )[$\w]+(?=\.Tray\b)'`
- Hard-fails the build (`exit 1`) if neither resolves.

### `fix_native_theme_references` (_common.sh)

Fix-up for an *upstream minifier bug* class (issues #218/#219, where
Anthropic's own bundle referenced `oe.nativeTheme` while electron was bound
to `Ae`): greps every `[$\w]+(?=\.nativeTheme)` occurrence, `sort -u`,
drops the one equal to `$electron_var`, and rewrites each survivor with
`sed -i -E "s/${ref_re}\.nativeTheme/${electron_var_re}.nativeTheme/g"`.
No-op ("All nativeTheme references are correct") when nothing mismatches.

### `patch_tray_menu_handler` (tray.sh)

Targets the tray rebuild function that upstream wires to the
`menuBarEnabled` setting and to `nativeTheme.on("updated")`.

- Extracts `tray_func` via anchor
  `'on\("menuBarEnabled",\(\)=>\{\K[\w$]+(?=\(\)\})'` and `tray_var` via
  `'[$\w]+(?=\s*=\s*new\s+[$\w]+\.Tray\()'` (hard-fail if either is empty).
- Rewrites `function TRAY_FUNC(){` → `async function TRAY_FUNC(){`,
  guarded by `grep -q "async function ${tray_func}(){"` because upstream
  1.8089.1 already ships it async — re-applying would emit
  `async async function` (guard added in 6219d5a, PR #627).
- Injects a **trailing-edge mutex**: `if(FN._running){FN._pending=true;
  return}FN._running=true;setTimeout(()=>{FN._running=false;
  if(FN._pending){FN._pending=false;FN()}},1500);` — prevents
  concurrent/reentrant rebuilds while remembering a request that arrives
  mid-flight so the FINAL `nativeTheme` value wins (the in-file comment
  cites the ~50 ms startup window where `shouldUseDarkColors` reads false;
  see docs/learnings/tray-rebuild-race.md). Idempotency: keyed on
  `grep -q "${tray_func}._running"`.
- Injects a **250 ms DBus cleanup delay**: rewrites
  `TRAY&&(TRAY.destroy(),TRAY=null)` →
  `TRAY&&(TRAY.destroy(),TRAY=null,await new Promise(r=>setTimeout(r,250)))`
  so the StatusNotifierItem has time to unregister before a new
  `new Tray()` registers.

### `patch_tray_icon_selection` (tray.sh)

Rewrites the hardcoded macOS template-icon assignment into a
theme-conditional pick:

```
s/:([[:alnum:]_$]+)="TrayIconTemplate\.png"/:\1=${dark_check}?"TrayIconTemplate-Dark.png":"TrayIconTemplate.png"/g
```

where `dark_check` is `${electron_var_re}.nativeTheme.shouldUseDarkColors`.
The icons themselves were made opaque at build time (ImageMagick, in the
deleted `scripts/staging/icons.sh` pipeline) because the originals are
macOS-style ~20% opacity templates that Linux never colorizes (e5d58f2).
Anchor probe `grep -qP ':[$\w]+="TrayIconTemplate\.png"'` doubles as the
idempotency guard.

### `patch_tray_inplace_update` (tray.sh)

The KDE Plasma duplicate-SNI fix (#515). Dynamically extracts five
minified locals, then uses an embedded `node -e` program to inject a
fast-path *before* the destroy+recreate block:

```
if(TRAY && ENABLED!==false){
  TRAY.setImage(EL.nativeImage.createFromPath(PATH));
  process.platform!=="darwin" && TRAY.setContextMenu(BUILDER());
  return
}
```

Extraction details (all warn-and-skip rather than hard-fail, except the
node stage which hard-fails):

- `tray_func` / `local_tray_var`: same anchors as the menu handler
  (re-extracted because the menu handler declares them `local`).
- `menu_func`: first tries `TRAY.setContextMenu\(\K[\$\w]+(?=\(\))`
  (inline-builder shape); on the 1.13576+ prebuilt-object shape it walks
  *every* `setContextMenu` argument, skips the `setContextMenu(null)`
  menu-clear decoy, and resolves the first that matches a
  `(?<![\$\w])VAR=\K[\$\w]+(?=\(\))` builder assignment (6091615 +
  55bc328). Both-empty emits a loud stderr WARNING naming the #515 race
  (2ad33d3).
- `path_var`: from
  `TRAY=new EL\.Tray\(EL\.nativeImage\.createFromPath\(\K[\$\w]+(?=\))`.
- `enabled_var`: from `const \K[$\w]+(?=\s*=\s*[$\w]+\("menuBarEnabled"\))`
  with a count-must-equal-1 bail (added in the #515 PR follow-up commit).
- Idempotency marker: the literal post-rename string
  `TRAY.setImage(EL.nativeImage.createFromPath(PATH))`.
- Injection: locate `TRAY.destroy()` (asserted to occur exactly once,
  else loud fail — eb12ad8), `lastIndexOf(';if(', di)` to walk back to the
  opening statement boundary, splice the fast-path after the `;`. Robust
  across both the old `;if(TRAY&&(TRAY.destroy()...` and the 1.13576+
  `;if(X=[],Y=!1,TRAY&&(TRAY.destroy()...` shapes (6091615).

## Origin

Three distinct origins, in chronological order:

1. **Menu handler (mutex + DBus delay)** — commit `1bb05df`, 2025-11-08,
   "Fix non-functional tray menu on Wayland Linux", merged via PR #138.
   Message: "Add mutex guard and async delay to BI() function to prevent
   concurrent Tray creation. Eliminates DBus 'already exported' errors and
   makes menu items (Show App, Quit) functional on Wayland. Fixes #135."
   The first version hardcoded the minified names `BI`/`Yn` and used a
   500 ms mutex + 50 ms post-destroy delay, applied with plain `sed` in
   `build.sh`. The same day, `c660bf1` (PR #139) replaced the hardcoded
   names with dynamic extraction — introducing the
   `on("menuBarEnabled",()=>{FUNC()})` anchor that survives to this day.
   Context: adjacent tray-icon asset work (`47c1889`, PR #134, issue #122
   "is there a way to display the tray icon") landed one day earlier, but
   that is icon staging, not this unit's bundle patching.

2. **Icon selection** — commit `e5d58f2`, 2026-01-19, "fix: make tray icon
   visible on Linux by processing template icons", "Related to #163".
   Rationale from the message: the shipped icons are macOS templates
   ("dark shapes with ~20% opacity") that rely on OS colorization Linux
   doesn't do, so they render invisible; the patch selects
   `TrayIconTemplate(-Dark).png` by `shouldUseDarkColors` and ImageMagick
   makes them opaque. The selection logic was inverted on day one and
   corrected the next day (`e29635f`, 2026-01-20: "-Dark suffix in macOS
   naming means 'for dark mode' (white icon)").

3. **In-place fast-path** — commit `cf2b0fc`, 2026-04-27, PR #515 by
   @IliyaBrook, "fix: update Linux tray icon in place on OS theme change".
   Message: the existing 250 ms delay "is not enough on all setups
   (reproduced on Fedora 43 KDE Plasma 6.6.4 + Wayland). Widening the
   delay just moves the goalposts; the race is structural" — destroy +
   recreate leaves the old StatusNotifierItem registered while the new one
   appears, showing two Claude icons until logout. Follow-up to closed PR
   #491 (icon-color submenu feature) whose duplicate-icon fix was split
   out per the scope discussion in GitHub Discussion #492.

4. **fix_native_theme_references / extract_electron_variable** — commit
   `7bd2f38`, 2026-02-08, "fix: use regex extraction for electron variable
   in tray patches … Auto-fix any upstream minifier bugs in nativeTheme
   references. Fixes #218 Fixes #219". Motivated by upstream v1.1.2321
   shipping its *own* minifier bug (`oe.nativeTheme` vs electron bound to
   `Ae`), which broke the tray icon. The logic was inline in `build.sh`;
   `4043474` (same day) extracted it into the named helper functions.
   The `electron_var_re` half of the contract documented in Mechanism
   arrived two weeks later in `546f845` (2026-02-24, "Fixes #252"):
   upstream v1.1.4088 minified the electron binding to `$e`, the
   `\b\w+` capture grabbed only `e`, and every downstream sed spliced
   code between the `$` and the `e` — producing a `$let _trayStartTime`
   SyntaxError at launch. That commit widened the anchors to `\$?\w+`,
   introduced the `$`-escaped `electron_var_re` global, and switched
   `fix_native_theme_references` to `grep -Fxv` + `ref_re` escaping. It
   is the *first* hit of the `$`-identifier trap in this unit; the trap
   recurred three months later on `tray_func` (`i$A`, upstream 1.8089.1,
   `6219d5a`) — 6219d5a's own message cites "the same way _common.sh
   already does for electron_var with \$?\w+", i.e. 546f845's pattern.

## Revision history

Substantive changes only, date order. Causes are quoted/paraphrased from
commit messages unless marked *(inference)*.

| SHA | Date | Change | Why |
|---|---|---|---|
| `1bb05df` | 2025-11-08 | Origin: async + 500 ms mutex + 50 ms post-destroy delay on `BI()`/`Yn` (hardcoded) | DBus "already exported" errors; non-functional tray menu on Wayland (Fixes #135, PR #138) |
| `c660bf1` | 2025-11-08 | Dynamic extraction of `TRAY_FUNC`/`TRAY_VAR` via the `menuBarEnabled` listener anchor | Minified names change between releases (PR #139) |
| `bed0cc3` | 2026-01-12 | Mutex inserted right after the function brace instead of matching the first `const` | Upstream 1.0.3218 added an early-return before the first const; patch failed (PR #158, @lizthegrey) |
| `e5d58f2` | 2026-01-19 | Icon-selection patch + ImageMagick opacity processing added | Template icons invisible on Linux (#163) |
| `e29635f` | 2026-01-20 | Inverted icon logic corrected (dark theme → `-Dark.png` white icon); resilient `\w` regex | `-Dark` means "for dark mode"; day-one logic was backwards |
| `6916a9e` | 2026-01-20 | Mutex 500→1500 ms; post-destroy delay 50→250 ms; removed ineffective `--disable-features=UseStatusIconLinuxDbus` from PR #164 | Root cause of #163: `Tray.destroy()` returns before DBus unregisters; the #164 flag "doesn't exist in Electron/Chromium" |
| `bbf3b99` | 2026-01-21 | `_trayStartTime` 3-second startup-suppression window in the `nativeTheme "updated"` handler | Startup theme events raced the initial tray creation past the mutex (#163); also added CLAUDE.md minified-JS guidelines |
| `29173e9` | 2026-01-22 | build.sh organized into named functions (structural move) | Refactor |
| `7bd2f38` | 2026-02-08 | Electron-var extraction from `require("electron")`; auto-fix of wrong `X.nativeTheme` refs; menuBarEnabled default | Upstream minifier bug `oe` vs `Ae` in v1.1.2321 broke the tray (Fixes #218, #219) |
| `4043474` | 2026-02-08 | Inline logic extracted into `extract_electron_variable()` + `fix_native_theme_references()`; mapfile loop | Refactor of the same day's fix |
| `546f845` | 2026-02-24 | Electron-var anchors widened `\b\w+`→`\$?\w+`; `electron_var_re` (`$`-escaped) global introduced; `fix_native_theme_references` switched to `grep -Fxv` + `ref_re` escaping | Upstream v1.1.4088 minified the electron binding to `$e`; `\w`-only capture grabbed just `e` and downstream seds inserted code between `$` and `e`, producing a `$let _trayStartTime` SyntaxError at launch (Fixes #252) |
| `2017011` | 2026-02-25 | `_trayStartTime` gating sed widened to accept a preceding call with arguments (`(\w+\([^)]*\))` instead of `(\w+)\(\)`) | Upstream v1.1.4173 emitted `B1(bm-1)` before the tray call, so bbf3b99's startup-suppression sed silently missed ("Fix tray startup delay sed pattern to handle function calls with arguments"; carried in the cowork-gate fix, Fixes #259) |
| `4cd0f81` | 2026-02-27 | Icon-selection grep/sed identifier capture `\w`→`\w+` (probe and sed) | "handle multi-character minified variable names in future upstream versions" (commit message; same regex-resilience class as e29635f/6219d5a/b40441c) |
| `ff4821e` | 2026-04-20 | Split out of build.sh into `scripts/patches/tray.sh` + `_common.sh` (structural move) | "refactor: split build.sh into topical modules under scripts/" |
| `cf2b0fc` | 2026-04-27 | `patch_tray_inplace_update` added: setImage/setContextMenu fast-path before destroy+recreate; 5-way dynamic extraction; enabled_var count-bail | Structural KDE Plasma duplicate-SNI race; 250 ms delay insufficient (PR #515, @IliyaBrook) |
| `6219d5a` | 2026-05-20 | `[\w$]+` identifier captures; `tray_func_re` `$`-escaping; async-rewrite idempotency guard | Upstream 1.8089.1 minifier emits `i$A`; PCRE `\w` misses `$` → "Failed to extract tray menu function name" build abort (#625, PR #627, @typedrat) |
| `b40441c` | 2026-05-24 | Repo-wide regex hardening: `[$\w]+`/`[[:alnum:]_$]+` everywhere incl. 3 `_common.sh` sites; fixed always-true idempotency guard (`grep -q` pipe); removed dead `first_const`; multi-site coordination check | Audit against CLAUDE.md + patching-minified-js.md guidelines (PR #644) |
| `e38066e` | 2026-05-27 | `tray_var` anchor moved from `});let X=null;function FN` to the `VAR = new EL.Tray(` literal | Upstream 1.9255.0 reshuffled declarations, breaking the structural anchor (Fixes #656) |
| `e13e331` | 2026-06-02 | Mutex made trailing-edge (`_pending` re-run); `_trayStartTime` window removed; menu_func resolver handles prebuilt-menu shape | On dark desktops `shouldUseDarkColors` reads false for ~50 ms; leading-edge mutex dropped the corrective events → icon stuck black (Fixes #679, PR #680, @LiukScot) |
| `55bc328` | 2026-06-02 | menu_func fallback: word-boundary lookbehind `(?<![$\w])` | Review finding on PR #680: `let/const M=BUILDER()` declarator shapes returned empty → silent skip |
| `2ad33d3` | 2026-06-04 | Both-paths-empty menu_func resolution upgraded from info "skipping" to stderr WARNING | "A silent skip here is how the #515 duplicate-icon race regressed before" (landed with PR #680) |
| `6091615` | 2026-06-26 | Re-derivation for the 1.13576+ "yukonSilver" refactor: null-decoy-skipping resolver walk; injection via `indexOf(TRAY.destroy())` + `lastIndexOf(';if(')`; `menuBarEnabled:!0` defaults-map recognition; `tests/tray-patches.bats` (7 cases) | Upstream restructured the guard to `if(X=[],Y=!1,TRAY&&(TRAY.destroy()...` and prebuilt the menu with a `setContextMenu(null)` first-in-file decoy; fast-path silently skipped through green CI, re-arming the #515 race (issue #750; warn-and-continue class = #429) |
| `eb12ad8` | 2026-06-26 | Assert exactly one `TRAY.destroy()` anchor (loud fail on ambiguity); default probe `\s*`→`[ \t]*`; +1 bats case | Hardening per docs/learnings/patching-minified-js.md review; a second destroy site would silently mis-place the injection |

## Related issues and PRs

| # | Kind | Title | State | Role |
|---|---|---|---|---|
| #122 | issue | is there a way to display the tray icon | closed | Original tray-icon-visibility report; led to adjacent icon-staging PR #134 the day before this unit's origin |
| #134 | pr | Consolidate icon processing and fix tray icon runtime access | merged 2025-11-07 | Adjacent icon-asset work preceding the unit; context for origin |
| #135 | issue | Correct DBUS issue from Frame-Fix script | closed | Motivated `patch_tray_menu_handler` (1bb05df "Fixes #135") |
| #138 | pr | Fix non-functional tray menu on Wayland Linux | merged 2025-11-08 | Landed the origin commit 1bb05df |
| #139 | pr | v1.1.10: Tray icon fixes and system integration improvements | merged 2025-11-08 | Landed c660bf1 (dynamic extraction) |
| #158 | pr | Update Claude Desktop to version 1.0.3218 | merged 2026-01-13 | Landed bed0cc3 resilience fix (@lizthegrey) |
| #163 | issue | Duplicate tray icons and broken icon rendering in Claude 1.x | closed | Motivated icon selection (e5d58f2), delay increases (6916a9e), startup window (bbf3b99) |
| #164 | pr | fix: prevent duplicate tray icons on KDE systems | merged 2026-01-20 | First attempt at #163 via a nonexistent Chromium flag; superseded by 6916a9e which calls it out |
| #214 | issue | Small tray icon | closed | Adjacent tray-icon sizing report (GNOME); linkage to this unit's fixes not traced |
| #218 | issue | Tray icon missing — Anthropic's app.asar has oe/Ae minifier bug + menuBarEnabled config reset on update | closed | Motivated `fix_native_theme_references` + electron-var extraction (7bd2f38 "Fixes #218") |
| #219 | issue | Tray icon patch uses wrong variable name (oe vs Ae) in v1.1.2321 | closed | Same-bug report, fixed by 7bd2f38 ("Fixes #219") |
| #252 | issue | SyntaxError on launch: Stray `$` in `index.js` breaks v1.3.12+claude1.1.4088 | closed | Motivated 546f845's `$`-prefix electron-var anchors + `electron_var_re` global (commit says "Fixes #252"); first field hit of the `$`-identifier trap |
| #259 | issue | Bug: App window never creates on Linux (WOt() throws due to missing formatMessage id) | closed | v1.1.4173 startup-crash report; its fix commit 2017011 (primarily the cowork platform-gate repair) also carried this unit's `_trayStartTime` sed widening |
| #429 | issue | build.sh patches warn-and-continue on missed anchors — broken patches ship via green CI | open | Systemic context: why the yukonSilver breakage (#750) shipped silently; cited in #750's body |
| #491 | pr | feat: add "Icon color" submenu for Linux tray (Auto/Black/White) | closed, unmerged | Precursor to #515; its duplicate-icon fix was split out per cf2b0fc's message (scope discussion = GitHub Discussion #492, "PR 491 - Adding functionality") |
| #515 | pr | fix: update Linux tray icon in place on OS theme change | merged 2026-04-27 | Landed `patch_tray_inplace_update` (cf2b0fc, @IliyaBrook) |
| #557 | issue | sys tray icon displays a cryptic transparent window full of source code (Linux Mint Cinnamon X11) | open | Tray-adjacent open report found via search; linkage to this unit unverified |
| #563 | issue | KDE Wayland: system tray icon follows Claude app theme instead of desktop/panel theme | open | Known limitation of the `shouldUseDarkColors` icon-selection heuristic; cited as distinct in #679's title |
| #588 | issue | icon of claude in taskbar in XFCE isn't showing properly | open | Icon-adjacent open report found via search; linkage to this unit unverified |
| #604 | issue | tray icon invisible on LMDE 7 / Cinnamon — Mint-Y-Dark-Aqua dark panel + light colour-scheme | open | Same heuristic-limitation class; cited as distinct in #679's title |
| #625 | issue | [bug]: nix build failure on decb512 | closed | Regression report: `$`-identifier extraction abort on 1.8089.1; fixed by PR #627 |
| #627 | pr | fix(tray): support $-containing identifiers in 1.8089.1 minified bundle (#625) | merged 2026-05-21 | Landed 6219d5a (@typedrat) |
| #644 | pr | fix(patches): harden regex patterns for minified JS identifiers | merged 2026-05-25 | Landed b40441c hardening audit |
| #656 | issue | Tray patch fails to extract electron variable on upstream 1.9255.0 | closed | Anchor rot report; fixed by e38066e |
| #679 | issue | tray icon stuck black at startup on dark GNOME — corrective nativeTheme "updated" dropped by the rebuild mutex | closed | Regression *caused by* the leading-edge mutex; fixed by PR #680 |
| #680 | pr | fix(tray): startup icon stuck black — make rebuild mutex trailing-edge (#679) | merged 2026-06-04 | Landed e13e331 + 55bc328 + 2ad33d3 (@LiukScot) |
| #746 | issue | Menu bar icon is broken after update to v. 1.15200.0 | open | Investigation surfaced #750; per #750's body it is NOT root-caused to this unit ("the core icon-selection patch still applies on both 1.15200.0 and 1.15962.0") |
| #750 | issue | tray.sh in-place fast-path silently broken on 1.13576+ (yukonSilver rebuild refactor) → #515 duplicate-icon race re-arms | open | Tracking issue for the breakage fixed by 6091615/eb12ad8; still open pending KDE-host runtime confirmation |

## Learnings

- `docs/learnings/tray-rebuild-race.md` — the unit's dedicated deep-dive:
  why destroy + 250 ms + recreate is structurally racy on KDE Plasma
  (window between SNI unregister signal and plasmoid reaction can exceed
  250 ms → two icons until logout), the verified KDE System Settings
  triggers (Colors / Plasma Style / Global Theme), the in-place fast-path
  JS, the five-local extraction table, the idempotency-marker rationale,
  the Fedora 43 / Plasma 6.6.4 repro recipe, and (appended by PR #680) the
  startup icon-colour race: `shouldUseDarkColors` false for ~50 ms then a
  burst of "updated" events, which a leading-edge mutex latches wrong.
- `docs/learnings/patching-minified-js.md` — general patch-suite lessons
  repeatedly applied to this unit: anchor selection (literals over
  identifiers → e38066e), the `\w`-vs-`$` identifier trap (first hit
  546f845, then 6219d5a, b40441c), idempotency guards, non-unique anchor
  disambiguation
  (→ eb12ad8's single-destroy assertion, which cites this doc).
- `docs/learnings/official-deb-rebase-verification.md` — records the
  delete verdicts and byte evidence (below).

## Fate under the official-deb rebase

Verdict per the patch-necessity matrix in
`docs/learnings/official-deb-rebase-verification.md` (verified against
official 1.17377.2, audited 2026-07-02) — two rows, quoted verbatim:

> | `tray.sh` mutex/delay/in-place | **delete** | Official rebuild takes
> an in-place `setImage` branch keyed on icon-path change;
> `Tray.destroy()` only runs when the user disables the tray. No SNI
> re-registration gap exists. |

> | `tray.sh` icon selection | **delete** | The `TrayIconTemplate.png`
> anchor survives only in the macOS `template-image` branch. The Linux
> `png` branch natively selects `TrayIconLinux(-Dark).png` (GNOME or dark
> theme → Dark). |

In other words: upstream independently converged on exactly what
`patch_tray_inplace_update` injected (in-place `setImage`, destroy only on
user-disable), and ships purpose-made opaque Linux tray icons
(`TrayIconLinux.png` / `TrayIconLinux-Dark.png`) with native theme-aware
selection — obsoleting the mutex, the 250 ms delay, the fast-path, and the
icon-selection rewrite at once. The rows are reproducible with
`tools/patch-necessity-audit.sh` (`probe_tray` counts `TrayIconLinux` +
`setImage` refs; `probe_tray_template_icon` confirms the
`:[$\w]+="TrayIconTemplate\.png"` anchor is absent from the Linux branch).

How the working tree (branch `rebase/official-deb`) handles it:

- Commit `d9cef9e` ("feat(rebase): Phases 1+2") deleted
  `scripts/patches/tray.sh` (313 lines), `scripts/patches/_common.sh`
  (56 lines), `tests/tray-patches.bats` (167 lines), and
  `scripts/staging/icons.sh` (the ImageMagick icon pipeline). The commit
  message lists "tray.sh", "menuBarEnabled default", and "i18n +
  tray-icon asar copies" among the "11 condemned patches deleted".
- `scripts/patches/app-asar.sh` on the working tree defines
  `active_patches=(patch_quick_window patch_org_plugins_path)` — no tray
  entry; the header documents the patch-zero contract (empty array →
  official app.asar ships byte-identical).
- `grep -rn 'extract_electron_variable\|fix_native_theme_references\|electron_var' scripts/ build.sh`
  on the working tree returns nothing: both `_common.sh` helpers are gone
  with no remaining consumer (the two survivor patches do their own
  extraction).
- Icons: per d9cef9e, "icons come from the official hicolor set" —
  `scripts/staging/icons.sh` is not replaced by any tray-icon processing.

Open item attached to the verdict: none for the tray rows themselves (both
are unconditional deletes, unlike the two "survivor candidate" rows).
Issue #750 remains open on `main` for the legacy pipeline, but it is mooted
by the rebase deleting the patch it tracks.

## Gaps

- **No explicit matrix row for `fix_native_theme_references`.** Its
  deletion is implied by tray.sh's deletion (its consumers were the tray
  patches; d9cef9e removed `_common.sh` wholesale), but I found no
  byte-level check that official 1.17377.2 is free of the #218/#219-class
  `X.nativeTheme` minifier bug — `tools/patch-necessity-audit.sh` has no
  probe for it. Deletion-by-implication is *(inference)*, the file
  deletions are fact.
- **#750's runtime confirmation was never closed out**: 6091615's message
  says "Runtime confirmation of the #515 race avoidance still needs a KDE
  Plasma host", and #750 is still open. Moot for the rebase, unresolved
  for main.
- **#214, #557, #588 linkage unverified** — tray-adjacent reports found
  via search; I did not trace whether this unit's code caused or fixed
  them.
- **#746 root cause is unresolved upstream of this dossier** — #750
  explicitly rules this unit's fast-path out as the cause, but what does
  cause the 1.15200.0 icon breakage is not established here.
- **#492 is a GitHub Discussion** ("PR 491 - Adding functionality"), not
  an issue or PR, so it cannot be represented in the structured issueRefs;
  recorded here only.
- Pre-`1bb05df` tray patching: pickaxe and `--grep=tray` searches surface
  nothing earlier that modifies the bundle's tray code (only icon-asset
  staging, PR #134). I treat 1bb05df as the true origin of in-bundle tray
  patching; if an even earlier form existed under different vocabulary it
  did not surface in `-S 'menuBarEnabled'`, `-S '_running'`, or
  `-S 'TrayIconTemplate'` pickaxes.
