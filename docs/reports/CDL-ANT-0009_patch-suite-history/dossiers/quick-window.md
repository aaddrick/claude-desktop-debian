# Dossier: Quick Entry window focus/blur patch (KDE stale-focus)

Unit: `scripts/patches/quick-window.sh` (`patch_quick_window`) on `main`.
A two-part runtime patch of the minified main-process bundle
(`app.asar.contents/.vite/build/index.js`) that works around Electron's
stale `BrowserWindow.isFocused()` on Linux/KDE so the main window
reappears after a Quick Entry submit.

## Mechanism

Source read via `git show main:scripts/patches/quick-window.sh`. The
function header states the intent: "KDE-gated blur/focus workarounds for
the pop-up menu so the main window reappears after quick-entry submit."

### Dynamic identifier extraction

- Quick-window variable: extracted from the unique `"pop-up-menu"`
  always-on-top call —
  `grep -oP '[$\w]+(?=\.setAlwaysOnTop\(\s*!0\s*,\s*"pop-up-menu"\))'`
  (`quick-window.sh`, top of `patch_quick_window`). If empty, the patch
  warns and returns without touching the bundle.
- Focus-check function: the Node heredoc finds it via the surviving
  property name — `/isWindowFocused:\s*\(\)\s*=>\s*!!([\w$]+)\(\)/`
  (`focusedPropRe`).
- Visibility function: located within 500 chars of the focus function via
  `visFnRe = /function (\w+)\(\)\{(?:var [\w$]+(?:,[\w$]+)*;)?return![\w$]+\|\|[\w$]+\.isDestroyed\(\)\?!1:[\w$]+\.isVisible\(\)/`
  — the `(?:var …;)?` prefix tolerates the minifier hoisting a `var e;`
  declaration (1.3883.0+ shape, see d4db728 below).

### Part 1 — blur() before hide() (sed)

Anchor: `\|\|\s*${quick_var_re}\.hide\(\)` (the hide call sits after `||`
in a short-circuit guard, e.g. `GUARD()||VAR.hide()`). The sed rewrite
injects a desktop-environment ternary:

```
||((process.env.XDG_CURRENT_DESKTOP||"").toLowerCase().includes("kde")
   ? (VAR.blur(),VAR.hide()) : VAR.hide())
```

Effect: on KDE, `blur()` runs before `hide()` so `isFocused()` returns
false after the popup hides (Electron Linux bug); on any other DE the
original unconditional `hide()` runs. Idempotency guard:
`grep -qF "${quick_var}.blur(),${quick_var}.hide()"` — the injected pair
appears literally inside the ternary, so re-runs skip cleanly.

### Part 2 — visibility check instead of focus check on show() (Node)

Anchored on two developer log strings that survive minification:
`'Navigating to existing chat'` and
`'Creating new chat with submit_quick_entry'`. Within a 1500-char region
after each anchor it matches `focusFn()||([\w$]+)\.show\(\)` and rewrites
it to:

```
((process.env.XDG_CURRENT_DESKTOP||"").toLowerCase().includes("kde")
   ? visFn() : focusFn()) || mainWin.show()
```

Effect: on KDE, the "don't show the main window if already focused" gate
uses `isVisible()` instead of the stale `isFocused()`, so
`mainWin.show()` actually fires after a Quick Entry submit. Non-KDE keeps
upstream's focus check (the GNOME regression #393 is why — comment in the
script cites it twice). Idempotency: if the region already contains
`XDG_CURRENT_DESKTOP`, the site is skipped. Extraction failures
`process.exit(1)` so the shell caller prints
`WARNING: Quick window show patch failed` (hardened in ee3d656).

## Origin

- **First commit:** `8d3de5b` — "Fix quick window submit issue",
  2025-12-13, author jacobfrantz1. Six lines added to `build.sh`:

  ```bash
  if ! grep -q 'e.blur(),e.hide()' app.asar.contents/.vite/build/index.js; then
      sed -i 's/e.hide()/e.blur(),e.hide()/' app.asar.contents/.vite/build/index.js
  ```

  Note the hardcoded minified variable `e` — the seed of the later
  rewrite.
- **Merged via PR #147** ("Fix quick window submit issue", merged
  2026-01-05, merge commit `11d44de`). PR body: "when submitting a prompt
  on the quick window, it would simply disappear and the user would have
  to manually open the main window (right click tray -> show app)… This
  fix gets around an Electron Linux issue where isFocused returns true
  after hiding the window if blur was not called. Fixes #144".
- **Motivating issue #144** ("UI Quick Search Bar not working", opened
  2025-12-03 by @malins): Kubuntu 24.04 (KDE), AppImage — typing in the
  Quick Entry popup and pressing Enter made the window silently
  disappear with no response surfaced.
- The upstream Claude Desktop version in play at origin is not recorded
  in the commit or PR (gap; the app was then repackaged from the Windows
  installer per the main-branch pipeline).

## Revision history

Substantive changes in date order (file moves noted for traceability):

1. `29173e9` (2026-01-22, part of #179 "Refactor build scripts…"):
   the inline block became the `patch_quick_window` function inside
   `build.sh`. Refactor only, no behavior change (commit message lists
   the new function inventory).
2. `32660be` (2026-04-12, PR #390) — **rewrite with dynamic symbol
   extraction.** Commit message states the cause: "The original patch
   from PR #147 hardcoded the minified variable name `e` … which stopped
   matching after upstream minifier changes renamed the variable. This
   silently regressed the fix for #144." Replaced with (1) the
   `setAlwaysOnTop(!0,"pop-up-menu")` anchor + parenthesized
   short-circuit-safe blur injection and (2) the new Part 2:
   focus-check → visibility-check swap at the two `[QuickEntry]`
   log-string-anchored `show()` sites. "Fixes #144" (again).
3. `ab33960` (2026-04-15, PR #406) — **gate both halves to KDE only.**
   Cause per commit message: "PR #390 fixed a quick-window regression on
   KDE but regressed GNOME/Ubuntu — @Andrej730 confirmed removing
   patch_quick_window restores quick entry on Ubuntu 24.04" (issue
   #393). Both parts wrapped in the
   `XDG_CURRENT_DESKTOP … includes("kde")` runtime ternary; added the
   Part 2 idempotency pre-check (`XDG_CURRENT_DESKTOP` near the anchor).
   Message calls it "a temporary gate" pending VM bisection of which
   half regresses GNOME. Refs #393, #370, #404.
4. `ff4821e` (2026-04-20): moved from `build.sh` to
   `scripts/patches/quick-window.sh` ("refactor: split build.sh into
   topical modules under scripts/"). Move only.
5. `31c557a` (2026-04-27, PR #420, @Andrej730): regex construction
   readability — extracted an `escapeRegExp` helper and used
   `String.raw` for the show() pattern. Non-behavioral.
6. `d4db728` (2026-04-27, PR #496, @Andrej730 + follow-up commit) —
   **visibility regexp updated for upstream re-minification.** Cause:
   issue #495 ("`patch_quick_window` partially failing in the recent
   build") — upstream 1.3883.0 emitted
   `function aZA(){var e;return!Qt…}` (the minifier hoists `var e;` when
   the body uses optional chaining), so `visFnRe` no longer matched the
   1.3109.0 shape `function L7A(){return!Ct…}`. The fix makes the
   `var …;` prefix optional. Commit message records end-to-end
   verification on live 1.3883.0 and a repro of the #390 behavior on
   Nobara KDE Plasma 6 Wayland.
7. `ee3d656` (2026-05-24, "fix: harden CI, build pipeline, and packaging
   scriptlets"): the Node block's two extraction-failure paths changed
   from `process.exit(0)` to `process.exit(1)` so a failed symbol
   extraction surfaces as `WARNING: Quick window show patch failed`
   instead of silently passing.
8. `b40441c` (2026-05-24, PR #644) — **identifier-regex hardening.**
   Audit against `docs/learnings/patching-minified-js.md` guidelines:
   `\w+` → `[$\w]+` in the quick-var grep, `focusedPropRe`, and
   `visFnRe` (minified names can contain `$`); `\s*` whitespace
   tolerance added to the `||hide()` grep/sed anchors; sed switched
   to `-E`.

(Substantive revisions after origin: 5 — items 2, 3, 6, 7, 8.)

## Related issues and PRs

| # | Kind | Title | State | Role |
|---|------|-------|-------|------|
| 144 | issue | UI Quick Search Bar not working | closed | Motivated the patch (KDE stale-focus symptom; cited "Fixes #144" in #147 and #390) |
| 147 | PR | Fix quick window submit issue | merged 2026-01-05 | Original implementation (@jacobfrantz1, commit 8d3de5b) |
| 179 | issue | Refactor build scripts for maintainability and readability | closed | Context for the 29173e9 function wrap (move, not behavior) |
| 390 | PR | fix: rewrite quick window patch with dynamic symbol extraction | merged 2026-04-12 | Rewrite after anchor rot silently no-oped #147; added the show()-site half; also the change that regressed GNOME |
| 393 | issue | Quick Entry doesn't create new session / doesn't open the main client (Ubuntu 24.04) | open | Regression caused by #390 (@Andrej730); motivated the KDE gate; drives the S31/S32 test cases |
| 370 | issue | Quick Entry window shows opaque square frame behind transparent content on KDE Wayland | open | Adjacent Quick Entry surface (upstream Electron 41.0.4 transparency regression), consolidated in the same sweep; Refs-cited by ab33960 — not fixed by this patch |
| 404 | issue | Quick Entry feature does not work properly | closed | Adjacent hotkey-side report (Fedora 43 GNOME, focus-bound shortcut); Refs-cited by ab33960; resolved on the launcher/portal track, not by this patch |
| 406 | PR | fix: gate quick window patch to KDE sessions only (#393) | merged 2026-04-15 | Revision: the KDE gate (commit ab33960) |
| 420 | PR | build.sh: improve regexp quick window patch regexp readibility | merged 2026-04-27 | Revision: readability refactor (@Andrej730, commit 31c557a) |
| 495 | issue | [bug]: `patch_quick_window` partially failing in the recent build | closed | Anchor-rot report (@Andrej730) fixed by #496 |
| 496 | PR | fix: update visibility function regexp | merged 2026-04-27 | Revision: visFnRe tolerates hoisted `var` decl (commit d4db728) |
| 644 | PR | fix(patches): harden regex patterns for minified JS identifiers | merged 2026-05-25 | Revision: `[$\w]+` + whitespace-tolerance hardening (commit b40441c) |

## Learnings

- `docs/learnings/patching-minified-js.md` (lines ~160-164) uses this
  unit as its first case study: "Original patch:
  `s/e.hide()/e.blur(),e.hide()/`. When `e` became `Sa`, it no-oped.
  The rewrite anchors on `"pop-up-menu"` …, the `isWindowFocused`
  property name …, and the `[QuickEntry]` log strings."
- `docs/testing/quick-entry-closeout.md` documents the upstream contract
  around the patch: the visibility-check function is upstream's
  "don't-show-if-already-focused optimization", and "the patch we apply
  is fixing a Linux-Electron bug, not diverging from upstream intent.
  Once `isFocused()` returns honest values on Linux, the patch could be
  retired." QE-19 defines the build fingerprint (grep the bundled JS for
  the injected `XDG_CURRENT_DESKTOP` gate string); QE-11/QE-12 capture
  the GNOME-mutter stale-focus black-box repro. Backed by test cases
  S09 ("Quick window patch runs only on KDE (post-#406 gate)"), S31,
  S32 in `docs/testing/cases/shortcuts-and-input.md`.
- `docs/learnings/official-deb-rebase-verification.md` — the fate row
  (quoted below) plus the open-items entry.
- Adjacent, not this unit:
  `docs/learnings/wayland-global-shortcuts-portal.md` covers the Quick
  Entry *hotkey* (the #404 side, launcher-level);
  `docs/learnings/test-harness-electron-hooks.md` covers intercepting
  the Quick Entry popup's `BrowserWindow` construction in the test
  harness.

## Fate under the official-deb rebase

Matrix row from `docs/learnings/official-deb-rebase-verification.md`
(verified against official 1.17377.2, audited 2026-07-02), verbatim:

> | `quick-window.sh` KDE blur/focus | **survivor candidate** | Quick window var `Ns`: the `\|\|hide()` anchor is present with no `blur()` — the Electron-on-KDE stale-focus bug likely persists. Verify on Plasma; keep only if it reproduces. |

Byte-level evidence and reproduction:

- `tools/patch-necessity-audit.sh` `probe_quick_window()` reproduces the
  row mechanically: extracts the quick var via the same `"pop-up-menu"`
  anchor, then reports `needed?` when `||VAR.hide()` count > 0 and
  `VAR.blur()` count == 0 — i.e. upstream still hides the popup without
  blurring, so the Electron-on-KDE stale-`isFocused()` condition is
  structurally unchanged in the official Linux build.
- Phase 2 build verification (commit `d9cef9e`, 2026-07-02): "Verified
  end-to-end with an appimage build against official 1.17377.2 amd64:
  both survivors applied on all anchors". The tracking plan
  (`.tmp/plans/official-deb-rebase-tracking.md:113`) records the
  extracted identifiers: "quick-window found `Ns`/`ex`/`ree` + both
  show() anchors".

How the working tree (rebase/official-deb) handles it now:

- `scripts/patches/app-asar.sh` wires it as one of exactly two survivors:
  `active_patches=(patch_quick_window patch_org_plugins_path)` (lines
  26-29), with the header comment: "patch_quick_window — … bundle still
  hides without blur() (pending Plasma repro; drop if it doesn't
  reproduce)". When the array is non-empty, `patch_app_asar` extracts
  the official `app.asar`, runs each patch function, and repacks
  preserving upstream's unpacked set; an empty array ships the official
  asar byte-identical ("patch-zero").
- `scripts/patches/quick-window.sh` itself is byte-identical between
  `main` and `rebase/official-deb`
  (`git diff main rebase/official-deb -- scripts/patches/quick-window.sh`
  is empty).
- The verdict is conditional. Open item in both
  `docs/learnings/official-deb-rebase-verification.md` ("Open items":
  "Quick Entry stale-focus repro on KDE Plasma with the official
  build.") and `.tmp/plans/official-deb-rebase-tracking.md:297-298`
  ("decides whether `patch_quick_window` stays").
- Not touched by `scripts/setup/official-deb.sh` (acquisition only),
  `scripts/cowork-fallback/`, `scripts/launcher-common.sh`, or
  `scripts/doctor.sh` — the only launcher-side Quick Entry references
  are the hotkey/portal comments in `launcher-common.sh:65,80`, which
  belong to the separate Wayland-shortcuts unit.

## Gaps

- The upstream Claude Desktop version current at origin (Dec 2025) and
  the exact upstream release whose re-minification renamed `e` (breaking
  the #147 patch some time before 2026-04-12) are not recorded in
  commits, PRs, or docs.
- The tracking plan records the identifiers `Ns`/`ex`/`ree` extracted
  from official 1.17377.2 but does not say which of `ex`/`ree` is the
  focus function vs. the visibility function; only `Ns` (the quick
  window variable) is attributed in the verification doc.
- Whether the KDE Plasma stale-focus bug actually reproduces with the
  official 1.17377.2 build is unverified — it is the open item the
  survivor verdict hinges on. The audit's "likely persists" is a static
  inference from the unchanged `||hide()`-without-`blur()` bytes, not a
  runtime observation.
- ab33960's commit message calls the KDE gate "temporary" pending a
  bisection of which half (blur vs. isVisible swap) regresses GNOME; no
  later commit on `main` records that bisection completing, and #393
  remains open, so the gate persisted as-is.
