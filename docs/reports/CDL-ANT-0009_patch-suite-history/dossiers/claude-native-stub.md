# Dossier: Native module stub (`claude-native-stub.js` replacing `@ant/claude-native`)

Unit: the JS stub that stands in for Anthropic's Windows-only native
binding, plus its two injection points in the legacy build.

- Files on `main`: `scripts/claude-native-stub.js` (107 lines),
  injection in `scripts/patches/app-asar.sh` (asar copy) and
  `scripts/staging/electron.sh` (unpacked copy), regression tests in
  `tests/claude-native-stub.bats`.
- Verdict under the v3.0.0 rebase: **delete** (official .deb ships a
  real Rust NAPI ELF binding).

## Mechanism

Unlike the sed-based patches, this unit never touches the minified
bundle. It is a module-resolution shadow: the bundle's
`require("@ant/claude-native")` is satisfied by a drop-in
`node_modules/@ant/claude-native/index.js` that the build writes into
**both** load contexts, because the Windows `.node` binary shipped at
that path cannot load on Linux:

- Inside the asar — `main:scripts/patches/app-asar.sh` lines 69–71:

  ```bash
  mkdir -p app.asar.contents/node_modules/@ant/claude-native || exit 1
  cp "$source_dir/scripts/claude-native-stub.js" \
      app.asar.contents/node_modules/@ant/claude-native/index.js || exit 1
  ```

- In the unpacked tree — `main:scripts/staging/electron.sh` lines
  22–24 (same `cp`, destination
  `$app_staging_dir/app.asar.unpacked/node_modules/@ant/claude-native/index.js`).

Idempotency is trivial (`mkdir -p` + `cp` overwrite); there are no
grep/sed anchors and no dynamic identifier extraction. The one
bundle-side coupling is documented in the stub itself: the bundle only
null-guards the module, not individual methods —
`(o=g2())==null?void 0:o.readRegistryValues(r)` (quoted in the
`main:scripts/claude-native-stub.js` comment block above
`readRegistryValues`) — so the stub must export every method upstream
calls, or the call throws during top-level execution.

Runtime surface of the stub on `main` (all in
`main:scripts/claude-native-stub.js`):

- `KeyboardKey` — frozen enum of 19 key codes (Backspace: 43 … Meta:
  187), present since the initial commit.
- `getWindowsVersion: () => "10.0.0"` — fixed spoof.
- Functional-on-Linux methods routed through Electron's native support
  via a `getWindow()` helper (focused window, else first non-destroyed
  window): `getIsMaximized()`, `flashFrame()`/`clearFlashFrame()`
  (comment: `Fixes: #149`; auto-clear on focus lives in
  `main:scripts/frame-fix-wrapper.js` line 539,
  `this.flashFrame(false); // Fixes: #149`), and
  `setProgressBar()`/`clearProgressBar()` (clamped 0–1 / reset −1).
- Windows-only no-ops: `setWindowEffect`, `removeWindowEffect`,
  `showNotification`, `setOverlayIcon`, `clearOverlayIcon`.
- Windows policy/registry no-ops added for the #729 startup hang:
  `readRegistryValues: () => []`, `writeRegistryValue`,
  `writeRegistryDword`, `getWindowsElevationType: () => "default"`,
  `getCurrentPackageFamilyName: () => null`.
- `AuthRequest` class with `static isAvailable() { return false; }` and
  a throwing `start()` — forces the login flow to fall back to the
  system browser.

Tests: `main:tests/claude-native-stub.bats` loads the stub in a bare
Node process and asserts the five registry/policy methods plus a
regression guard on the existing exports (header comment cites the
`>= 1.13576.0` unconditional-call behavior and #729).

## Origin

The stub is as old as the repository. Initial commit `d8f4bbe`
(2024-12-26, aaddrick, "Initial commit: Claude Desktop for Debian-based
Linux distributions") embeds it twice as heredocs in `build-deb.sh`
(lines 180–220 asar copy, 231–271 unpacked copy), targeting the then
un-namespaced `node_modules/claude-native/index.js`. That first version
was the `KeyboardKey` enum, `getWindowsVersion: () => "10.0.0"`, and
pure no-ops for everything else — no `getWindow()`, no `AuthRequest`.

Motivation: the project repackaged the **Windows** installer, whose
`claude-native` package is a Windows `.node` binary that cannot load on
Linux; without a substitute module, `require` fails at startup. There
is no GitHub issue behind the origin — it predates the tracker. The
initial `README.md` in `d8f4bbe` credits k3d3's
`claude-desktop-linux-flake` for "valuable insights into the
application's structure and the native bindings implementation"
(README line 7), which is the stated provenance of the approach (the
specific key-code values matching k3d3's work is inference from that
credit, not a verified byte-trace).

## Revision history

Substantive changes only, date order:

1. `ae6d3a3` (2025-11-05, aaddrick) "Bug Fix: Corrected Google
   authentication by adding AuthRequest class to claude-native stub" —
   added the `AuthRequest` stub (`isAvailable()` → false) so Google
   login falls back to the system browser. Fixed issue #121 ("Google
   login does not work, the 'Loading' spinner spins indefinitely");
   aaddrick closed #121 the same day citing this commit. Direct commit
   to main — the GitHub commits/pulls API returns no associated PR.
2. `5c5eb39` (2025-11-28, jacobfrantz1, PR #143 "Support claude
   desktop 1.0.1307 with code preview") — retargeted both heredoc
   destinations from `node_modules/claude-native/` to
   `node_modules/@ant/claude-native/`, tracking upstream 1.0.1307's
   package rename.
3. `1405e1c` (2025-11-28, aaddrick) "Revert download changes, fix
   missing mkdir for @ant namespace" — same-day follow-up adding the
   missing `mkdir -p` for the new namespaced directory before writing
   the stub (per the commit body).
4. `4bf5986` (2026-01-22, aaddrick, PR #180 "Refactor build scripts
   for maintainability and style guide compliance", merged to main via
   PR #181; commit body says "Part of #179") — extracted the heredoc to
   the standalone `scripts/claude-native-stub.js` and removed the
   duplicated second definition ("Remove duplicate claude-native stub
   (was defined twice)"); one source file, copied to both destinations.
5. `83cbb9a` (2026-02-14, vboi, PR #228 by @milog1994 "fix: improve
   Linux UX - popup detection, functional stubs, Wayland compositor
   support") — made `getIsMaximized`, `flashFrame`, `setProgressBar`
   functional "using Electron's native Linux support instead of
   no-ops" (commit body), introducing the `getWindow()` helper. Fixes
   list includes #149 (KDE Plasma attention flash), paired with the
   frame-fix-wrapper's focus auto-clear.
6. `2245808` (2026-02-16, aaddrick, PR #232, "Fixes: #231 item 3") —
   filtered destroyed/invisible windows out of the `getWindow()`
   fallback (`getAllWindows()[0]` could return a destroyed window →
   `flashFrame()` throws) and added `console.warn` in the catch block.
7. `75841f0` (2026-02-16, aaddrick, PR #232 review feedback) —
   **dropped** the `isVisible()` filter added two commits earlier "so
   flashFrame() works on minimized windows, which is its primary use
   case" (commit body); the surviving code comment on `main` documents
   this deliberately-absent check.
8. `9410db2` / `0fc8286` (2026-02-16, aaddrick, PR #232) — comment-only
   hardening: cross-reference comments linking the stub and
   frame-fix-wrapper for the flashFrame two-file interaction (#231
   item 9), and a TODO flagging that the popup fallback can mislead
   `getIsMaximized()`. (`b544a7b` in the same series is style-only;
   skipped.)
9. `ff4821e` (2026-04-20, "refactor: split build.sh into topical
   modules under scripts/") — pure move: injection logic lands in
   `scripts/patches/app-asar.sh` (asar copy inside `patch_app_asar`)
   and `scripts/staging/electron.sh` (unpacked copy inside
   `finalize_app_asar`).
10. `295d71b` (2026-06-24, Claude, PR #737, "fix(linux): stub
    Windows-only native policy methods to fix startup hang (#729)") —
    the last substantive change. Upstream >= 1.13576.0 calls
    `readRegistryValues()` and `getWindowsElevationType()`
    unconditionally at startup (managed-config/enterprise-policy
    lookup) from the top level of `index.pre.js`/`index.js`; the bundle
    guards only the module being null, not methods being absent, so the
    old stub threw `<method> is not a function` — swallowed by an empty
    `uncaughtException` handler, leaving the app hung with no window
    (issue #729). Added five neutral no-op policy methods and
    `tests/claude-native-stub.bats`. Commit body: "Consolidates the fix
    from #734 (complete stub) and #730 (test coverage), crediting both
    authors" (Co-Authored-By: chrisw1005, colonelpanic8).

## Related issues and PRs

| Ref | Kind | Title | State | Role |
|---|---|---|---|---|
| #121 | issue | Google login does not work, the "Loading" spinner spins indefinitely | closed | Motivated the `AuthRequest` stub; closed by aaddrick citing `ae6d3a3` |
| #143 | PR | Support claude desktop 1.0.1307 with code preview | merged 2025-11-29 | Moved the stub to the `@ant/claude-native` namespace (commit `5c5eb39`) |
| #149 | issue | KDE Plasma 6 + Wayland: Window demands attention on Alt+Tab… | closed | Motivated functional `flashFrame` + wrapper auto-clear; cited in stub comments |
| #179 | issue | Refactor build scripts for maintainability and readability | closed | Motivated extracting the heredoc to `scripts/claude-native-stub.js` (`4bf5986` says "Part of #179") |
| #180 | PR | Refactor build scripts for maintainability and style guide compliance | merged 2026-01-23 | Contains `4bf5986` (extraction + dedup) |
| #181 | PR | Merge next to main: Build script refactoring | merged 2026-01-23 | Merged the refactor branch to main |
| #228 | PR | fix: improve Linux UX - popup detection, functional stubs, Wayland compositor support | merged 2026-02-16 | Made stub methods functional (`83cbb9a`) |
| #231 | issue | Address review findings from PR #228 | closed | Review findings driving the `getWindow()` hardening series |
| #232 | PR | fix(issue-231): address review findings from PR #228 | merged 2026-02-16 | Landed `2245808`, `75841f0`, `9410db2`, `0fc8286` |
| #729 | issue | [bug]: hangs indefinitely, app window never shows up | closed | Regression report (upstream >= 1.13576.0 vs incomplete stub) fixed by `295d71b` |
| #730 | PR | Fix Linux startup with Claude native registry shim | closed, unmerged | @colonelpanic8's fix + test coverage, consolidated into #737 |
| #734 | PR | Fix Linux startup hang: stub Windows-only native methods (#729) | closed, unmerged | @chrisw1005's complete-stub fix, consolidated into #737 |
| #737 | PR | fix(linux): stub Windows-only native policy methods to fix startup hang (#729) | merged | Landed `295d71b`, the consolidated #729 fix |
| #762 | issue | Official Claude Desktop for Linux shipped: what does this project do now? | open | Context for the v3.0.0 rebase that deletes this unit (found via search; announces the official build whose real binding obsoletes the stub) |

Also found via search but **not verified as related**: #678
("claude-desktop remains hung before displaying anything", open,
reported at upstream 1.9659.2 — below the 1.13576.0 threshold in the
#729 fix; a #729 commenter (gwillen) judged the two "unlikely to be
related"). Listed here only for completeness; no evidence ties it to
this unit.

## Learnings

- `docs/learnings/official-deb-rebase-verification.md` (exists on the
  rebase branch working tree, not on `main`) — carries the unit's
  matrix row and the two-survivor budget accounting; see next section.
- No `docs/learnings/*.md` entry on `main` mentions `claude-native`
  (verified via `git grep 'claude-native' main -- docs/` → no hits).
  The unit's archaeology lived in code comments and commit bodies.
- Outside `docs/`: the official-Linux teardown (report CDL-ANT-0008,
  `.tmp/reports/linux-official-teardown/claude-desktop-linux-teardown.tex`)
  documents the unit's "community divergence" explicitly (line 290):
  the stub approximates or drops real input injection and peer-cred
  sockets, "the one capability the official build has that the
  community build cannot reproduce without reimplementing a Rust
  addon"; line 198/288 record the official binding as a 1.65 MB
  NAPI-RS Rust ELF with `enigo` + `x11rb` (XTEST) X11 input injection,
  `rustix`/`openat2` safe-fs containment, and `SO_PEERCRED` peer auth,
  with hardware-backed keys and web authentication "not yet supported"
  on Linux.

## Fate under the official-deb rebase

Matrix row, quoted verbatim from
`docs/learnings/official-deb-rebase-verification.md` line 23:

> | `claude-native-stub.js` | **delete** | Real Rust NAPI ELF at `resources/app.asar.unpacked/node_modules/@ant/claude-native/claude-native-binding.node`. |

Byte-level evidence: the teardown facts above (real 1.65 MB Rust NAPI
ELF with genuine X11 input injection), reproducible via
`tools/patch-necessity-audit.sh` on the working tree —
`probe_native_binding()` (lines 272–283) finds a `*.node` file under
`*claude-native*`, confirms ELF via `file`, and reports
`'claude-native-stub' 'not-needed'`.

How the rebase branch (working tree) handles it:

- **Deleted at `d9cef9e`** ("feat(rebase): Phases 1+2 — acquisition
  swap to the official .deb + patch triage"): both
  `scripts/claude-native-stub.js` (−107 lines) and
  `tests/claude-native-stub.bats` (−91 lines) are gone; neither
  injection site survives (`scripts/staging/` no longer exists;
  `grep -r 'claude-native' scripts/` on the working tree returns
  nothing).
- **The real binding ships as-is.** `scripts/setup/official-deb.sh`
  extracts the official `.deb`'s `data.tar` wholesale via `ar p | tar`
  (`_extract_deb_member`, lines 94–123), so
  `app.asar.unpacked/node_modules/@ant/claude-native/claude-native-binding.node`
  arrives untouched from upstream.
- **Repack preserves the unpacked set exactly.** The new
  `scripts/patches/app-asar.sh` (`active_patches=(patch_quick_window
  patch_org_plugins_path)`, lines 26–29 — no native-stub entry) derives
  its `--unpack` glob from the shipped `app.asar.unpacked` tree and
  hard-fails if the repacked unpacked set diverges (lines 82–113); with
  an empty array it ships the official `app.asar` byte-identical.
- **Doctor/launcher**: no native-binding checks exist in
  `scripts/doctor.sh` or `scripts/launcher-common.sh` on the working
  tree (grep for `native`/`.node` finds only Wayland-mode messages) —
  nothing to verify at runtime because upstream owns the module.
- **Known-stale, deliberate**: `tests/test-artifact-common.sh` lines
  80 and 116–118 still assert `@ant/claude-native/index.js` exists in
  both the unpacked tree and the asar. The tracking plan
  (`.tmp/plans/official-deb-rebase-tracking.md`, "Known-stale on the
  branch") assigns the `tests/test-artifact-*.sh` rework to @sabiut and
  states the `test-artifacts` CI jobs are "expected RED on this branch
  until that rework lands — coordinate, don't do."

The verdict is unconditional (not one of the two "survivor candidate"
rows or the "verify behaviorally" row), and no open item in the
verification doc's "Open items" list touches this unit.

## Gaps

- **KeyboardKey enum provenance**: the initial README credits k3d3's
  flake for "the native bindings implementation," but I did not
  byte-compare the enum values against k3d3's repository; attribution
  of the specific key codes is inference from that credit.
- **`ae6d3a3` review trail**: the AuthRequest commit has no associated
  PR (commits/pulls API empty) and no issue reference in its message;
  the #121 linkage rests on aaddrick's closing comment on #121 citing
  the commit, which is solid, but there is no record of why the
  `isAvailable() → false` design was chosen over a portal-based flow.
- **Official unpacked `index.js`**: I did not verify whether the
  official `.deb`'s `@ant/claude-native` directory also contains a JS
  loader named `index.js` next to the `.node` ELF — this determines
  whether the stale `test-artifact-common.sh` assertion coincidentally
  passes or fails on rebase artifacts. Moot for the verdict (suite
  rework is owned by @sabiut), but unrecorded.
- **#678**: whether that earlier hang report shares the #729 root cause
  is unverified in both directions; a commenter believed not.
- The exact upstream Windows Claude version bundled at the initial
  commit (2024-12-26) — and therefore the original `claude-native`
  method surface the first stub mirrored — was not reconstructed.
