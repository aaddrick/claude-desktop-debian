# Dossier: WCO/topbar shim (`patch_wco_shim`)

Unit: the UA-spoof shim that convinces the remote claude.ai bundle to render
its desktop topbar (hamburger / sidebar / search / nav / Cowork ghost) on
Linux. Files on `main`: `scripts/patches/wco-shim.sh` (`patch_wco_shim`) and
the injected payload `scripts/wco-shim.js`.

## Mechanism

**Build-time (`scripts/patches/wco-shim.sh`, `patch_wco_shim`, per
`git show main:scripts/patches/wco-shim.sh`):**

- Target: `app.asar.contents/.vite/build/mainView.js` (the BrowserView
  preload). Hard-fails (`exit 1`) if the file is missing.
- **No sed/regex anchor rewriting at all.** Unlike the rest of the patch
  suite, this patch performs a pure prepend: it reads
  `$source_dir/scripts/wco-shim.js` and writes
  `printf '%s\n%s' "$shim_content" "$original" > "$main_view"` — the shim
  source is inlined at the top of `mainView.js`.
- **Idempotency guard:** `grep -q '__claude_wco_shim' "$main_view"` → skip
  with "already has WCO shim". The marker is the first comment line of
  `scripts/wco-shim.js` (`// __claude_wco_shim — marker for patch_wco_shim
  idempotency check`).
- **Why inline instead of `require`:** in-file comment — "Sandboxed preloads
  can only require a fixed allowlist of modules (electron, ipcRenderer,
  contextBridge, webFrame…). A relative require to a sibling file fails with
  'module not found' and aborts the entire preload — taking
  desktopBootFeatures and the rest of mainView's exposeInMainWorld surface
  down with it." (Also recorded as a pitfall in
  `docs/learnings/linux-topbar-shim.md`.)
- **No dynamic identifier extraction.** The shim never touches minified
  identifiers in the bundled app; it overrides web-platform APIs so the
  *remote* claude.ai React bundle takes different branches. This made the
  unit immune to upstream re-minification by design — consistent with its
  zero-churn revision history (see below).
- Invocation on main: `scripts/patches/app-asar.sh` calls `patch_wco_shim`
  inside `patch_app_asar` with the comment "Inject WCO shim into the
  BrowserView preload so claude.ai's desktop topbar renders on Linux. The
  shim spoofs the bundle's isWindows() UA check (load-bearing) plus
  matchMedia and windowControlsOverlay (defensive)."

**Runtime (`scripts/wco-shim.js`, per `git show main:scripts/wco-shim.js`):**

Preload-side IIFE, `process.platform === 'linux'` only, disabled when
`CLAUDE_TITLEBAR_STYLE == 'native'` (default is `hybrid`;
`_resolve_titlebar_style` in `git show main:scripts/launcher-common.sh`
lines 120–127, mirrored in `scripts/frame-fix-wrapper.js` lines 41–68).
It builds a script string and runs it in the page's **main world** via
`webFrame.executeJavaScript`, with a page-side re-entry guard
`window.__claudeWcoShimInstalled`. Components (load-bearing designations
match the table in `docs/learnings/linux-topbar-shim.md`):

1. **Native-state probe** (diagnostic, not load-bearing): captures
   Chromium's real WCO state (`windowControlsOverlay.visible`,
   `getTitlebarAreaRect()`, `matchMedia` display-modes, UA) plus a phase-2
   `env(titlebar-area-*)` read via `--probe-*` custom-property indirection,
   deferred to `DOMContentLoaded` when needed. Logged as
   `[WCO Diagnostic] BrowserView native state:`. `CLAUDE_WCO_NATIVE=1`
   skips all overrides but keeps the probe (A/B diagnostic mode).
2. **`navigator.windowControlsOverlay` shim** (defensive): fake overlay
   object, `visible: true`, synthesized
   `DOMRect(0,0,innerWidth-140,40)`, full event-target semantics.
3. **`matchMedia` shim** (defensive): queries containing
   `window-controls-overlay` return `matches: true`.
4. **`navigator.userAgent` override — THE load-bearing part:** if
   `!/(win32|win64|windows|wince)/i.test(origUA)`, redefine the getter to
   return `origUA + " Windows"`. This flips the remote bundle's
   `isWindows()` gate (Gate 3 in the learnings doc) so React renders the
   topbar tree (`data-testid="topbar-windows-menu"`). Page-side only —
   the HTTP request UA is unchanged, "so analytics and anti-bot
   fingerprints stay honest" (shim comment).
5. **className intercept** (defensive): strips the `draggable` token from
   `Element.prototype.className` set, `setAttribute('class', …)`, and
   `DOMTokenList.prototype.add`, so claude.ai's
   `.draggable { -webkit-app-region: drag }` rule never matches inside the
   framed content area. Shim comment documents the known trade-off: class
   round-trip identity is broken for strings containing `draggable`.
6. **Event nudge** (defensive): `setTimeout(0)` dispatch of
   `geometrychange` + `resize` to wake frameworks that rendered before the
   shim arrived.

## Origin

- **Introducing commit:** `5c8191e` (2026-05-01, "feat(linux): hybrid
  titlebar mode for clickable in-app topbar (#538)"), merged as **PR #538**
  (aaddrick, merged 2026-05-01). Pickaxe confirms this is the true origin:
  `git log --oneline --reverse -S '__claude_wco_shim' main` and
  `-S 'windowControlsOverlay'` (code paths) both return only `5c8191e`.
  Both `scripts/patches/wco-shim.sh` and `scripts/wco-shim.js` have a
  single-commit history on main.
- **Situation at the time** (PR #538 body + `5c8191e` message +
  `docs/learnings/linux-topbar-shim.md`): the topbar is *not* in
  `app.asar` — claude.ai's remote React bundle renders it, gated by four
  independent gates. Gates 1 (server-delivered markup) and 2
  (`desktopTopBar.status == "supported"`) pass on Linux; **Gate 3, the
  `/(win32|win64|windows|wince)/i` UA regex, fails** on Linux's
  `X11; Linux x86_64` UA, so the topbar never rendered. PR #127
  (speleoalex, merged 2025-11-05, "feat: Add native window decorations
  support for Linux") had forced `frame: true` to fix missing window
  controls, "which definitively hid the topbar" (PR #538 body) — i.e. the
  Windows-style frameless+WCO route was off the table. The upstream
  `frame:false` + WCO config was independently broken on Linux: the
  investigation (Phase 2 in the learnings doc) disproved four hypotheses
  and landed on a Chromium-level implicit drag region for `frame:false`
  windows on both X11 and Wayland with no Electron-API knob ("Bug C"),
  making topbar buttons unclickable in `hidden` mode. Hybrid mode
  (system frame + page-side UA spoof) was the resolution, dated
  2026-04-29 in the learnings doc's Status section.
- **Same commit deleted the predecessor:** `scripts/patches/titlebar.sh`
  (`patch_titlebar_detection`), which stripped the `!` from
  `if(!isWindows && isMainWindow)` in the *bundled*
  `MainWindowPage-*.js` renderer assets (content per
  `git show 5c8191e^:scripts/patches/titlebar.sh`). That predecessor
  originated in `d6ed2c8` (2025-04-06, "feat: Bring build.sh from dev
  branch for title bar fix"; found via
  `git log --reverse -S 'MainWindowPage' main`). Issue **#45**
  ("Hamburger menu is missing, want to open developer mode", boyonglin,
  2025-03-28) is the earliest report of the missing-header symptom; its
  closing comment says "Issue resolved by pulling @emsi's window fix into
  the script" — the d6ed2c8-era fix. Linking #45 specifically to d6ed2c8
  is **inference from timing plus that comment**; the commit message
  carries no issue reference.
- **Version/context wiring in `5c8191e`:** the commit also added the
  `hybrid`/`native`/`hidden` mode machinery (`_resolve_titlebar_style` in
  `scripts/launcher-common.sh`, mode resolution + diagnostics in
  `scripts/frame-fix-wrapper.js`), a `--doctor` report of the resolved
  mode (`scripts/doctor.sh`), 16 bats cases in
  `tests/launcher-common.bats`, and the 367-line
  `docs/learnings/linux-topbar-shim.md` (stat block of `5c8191e`).

## Revision history

- **`5c8191e` 2026-05-01 — created** (PR #538). See Origin.
- **No substantive revisions on main after creation.**
  `git log main -- scripts/patches/wco-shim.sh scripts/wco-shim.js` shows
  exactly one commit. The zero-churn record is explained by the mechanism:
  the shim overrides web-platform APIs rather than grepping minified
  identifiers, so upstream re-minification never broke it. (`bdaff4a`
  2026-05-20 touched only the learnings doc in a cross-reference sweep,
  not the unit's code.)
- **`d9cef9e` 2026-07-02 (branch `rebase/official-deb`, not main) —
  deleted.** Commit message: "11 condemned patches deleted: frame-fix
  wrapper (incl. the autoUpdater no-op), claude-native stub, tray.sh,
  **wco-shim**, claude-code.sh, node-pty rebuild + nix/node-pty.nix,
  menuBarEnabled default, cowork/.config .asar guards, i18n + tray-icon
  asar copies." The surrounding titlebar machinery
  (`CLAUDE_TITLEBAR_STYLE`, `ELECTRON_USE_SYSTEM_TITLE_BAR`,
  CustomTitlebar/WCO Chromium flags, `_resolve_titlebar_style`) was
  removed from the launcher in `cafb4cc` 2026-07-02 (Phase 4 commit
  message, BREAKING).

## Related issues and PRs

| Ref | Kind | Title | State | Role |
|---|---|---|---|---|
| #538 | PR | feat(linux): hybrid titlebar mode for clickable in-app topbar | merged 2026-05-01 | Introduced the unit (commit `5c8191e`). Body documents the gate analysis and why hybrid beats upstream frameless+WCO. |
| #127 | PR | feat: Add native window decorations support for Linux | merged 2025-11-05 (speleoalex) | Predecessor/context: forced `frame:true` for native decorations, "which definitively hid the topbar" (PR #538 body) — created the missing-topbar state the shim fixed. |
| #45 | issue | Hamburger menu is missing, want to open developer mode | closed (opened 2025-03-28, boyonglin) | Earliest report of the missing-header/topbar symptom; resolved at the time by emsi's window fix (the `patch_titlebar_detection` predecessor era). Found via `gh search issues 'hamburger'`; never referenced by the shim's commits. |
| #85 | issue | Minimize, Maximize, Close Buttons not Visible | closed (opened 2025-06-29) | Matches the problem statement PR #127 fixed (missing window controls). **Inference** — PR #127 links no closing issues, so the connection is by subject matter only. |
| electron/electron#51396 | PR (external) | upstream Electron fix | — | Referenced in a PR #538 comment: "Issue and PR open with electron to fix the underlying issue that makes the shim a requirement" — i.e. the `frame:false` implicit drag region (Bug C). Not verified beyond that comment. |

**In-thread regression report (no repo issue filed):** PR #538 comment by
lukedev45 — partial topbar render on OmarchyOS + Hyprland after merge.
aaddrick reproduced the *symptom* only by disabling `patch_wco_shim`,
tested Omarchy's Ozone-Wayland env exports plus `CLAUDE_USE_WAYLAND=1` in
four scenarios without reproducing, and @typedrat confirmed working on
NixOS + Hyprland (also GNOME Wayland and Sway confirmations in-thread), so
the compositor alone was ruled out; diagnostics were requested from the
reporter. `gh search issues 'Omarchy'` finds no follow-up issue.

## Learnings

- **`docs/learnings/linux-topbar-shim.md`** (added in `5c8191e`) — the
  unit's design document: the four gates (Gate 3 `isWindows()` UA regex is
  the only load-bearing one), the per-component load-bearing table, the
  Phase 1/Phase 2 investigation chain (six failed escape attempts at the
  X11 drag-region map; the narrowing experiments proving `frame:false`
  itself is the source), three outstanding upstream bugs (A: WCO `@media`
  query never matches; B: WCO state doesn't propagate to BrowserView
  webContents; C: implicit drag region for frameless Linux windows,
  confirmed on X11 *and* Wayland 2026-04-29), the bundle-probe diagnostic
  recipe for re-discovering gates if claude.ai re-minifies, and pitfalls
  (sandboxed-preload require allowlist; `webFrame.executeJavaScript`
  firing before `document.documentElement` exists).
- **`docs/learnings/official-deb-rebase-verification.md`** — the rebase
  verdict (next section).
- CLAUDE.md's learnings index carries a summary line for
  `linux-topbar-shim.md` ("the four gates", "hybrid mode"). The rebase
  tracking plan (`.tmp/plans/official-deb-rebase-tracking.md` line 24 and
  line 237) marks the doc "obsoleted → archive after extracting
  Bugs A/B/C".

## Fate under the official-deb rebase

**Matrix row, verbatim**
(`docs/learnings/official-deb-rebase-verification.md`, line 21):

> | `wco-shim.sh` | **delete** | Never frameless, no UA spoof; `mainView.js` has no `windowControlsOverlay`/`isWindows` gating. |

**Byte-level evidence:**

- `tools/patch-necessity-audit.sh` `probe_wco_shim()` (lines 266–271):
  counts `'windowControlsOverlay|isWindows'` occurrences in the official
  `.vite/build/mainView.js` and reports verdict `not-needed`, "official
  never frameless / no UA spoof".
- "Never frameless" is corroborated by the matrix's `frame-fix-wrapper.js`
  row (same doc, line 17): "The only `frame:!1` sites are the Quick Entry
  popup and two transparent overlay windows — intentionally frameless on
  every platform. The main window omits `frame` (system frame)." With a
  system frame by default, the hidden-mode drag-region problem (Bug C)
  cannot arise, and there is no in-tree UA gate for the shim to satisfy.

**How the working tree (rebase branch) handles it now:**

- `scripts/patches/wco-shim.sh` and `scripts/wco-shim.js` are deleted
  (commit `d9cef9e`, 2026-07-02); neither exists in `scripts/` on the
  working tree.
- `scripts/patches/app-asar.sh` `active_patches=(patch_quick_window
  patch_org_plugins_path)` (lines 26–29) — no WCO entry; the array header
  documents the patch-zero contract ("the default verdict for any patch is
  delete, and when the array is empty the official app.asar ships
  byte-identical").
- `scripts/launcher-common.sh`: all titlebar machinery removed (commit
  `cafb4cc`); the LAUNCHER POLICY block (from line ~162) states the
  launcher "must NOT pass any default flag that shadows an official
  upstream code path (window frame, titlebar, …)".
- `scripts/doctor.sh` `_check_legacy_env()` (around lines 771–783) warns
  when `CLAUDE_TITLEBAR_STYLE` (among other 2.x knobs) is set: "is set
  but no longer honored since the v3.0.0 rebase onto the official build".

**Conditional part / open verification item** (the verdict is
delete-with-a-caveat): the shim's load-bearing target was never in
`app.asar` — it was the *remote* claude.ai bundle's `isWindows()` UA
regex, which is unverifiable statically from `.deb` bytes. The rebase
tracking plan (`.tmp/plans/official-deb-rebase-tracking.md`, lines
305–312, item added 2026-07-02) records exactly this: "the shell-side
`desktopTopBar` gate exists in official bytes, but the load-bearing gate
is the remote claude.ai bundle's `isWindows()` UA regex — unverifiable
statically. If the bundle still Windows-gates it, v3.0.0 loses the
hamburger/search/nav bar that v2.x hybrid mode delivered. One runtime
look (bundle-probe recipe in `docs/learnings/linux-topbar-shim.md`)
settles it; **if missing, it's an upstream report, NOT a shim revival**."
Note this open item appears only in the tracking plan — the verification
doc's own "Open items" section (lines 95–104) does not list it.

## Gaps

- **The runtime topbar check has not been performed.** Whether the
  official Linux build actually shows the in-app topbar (i.e., whether
  claude.ai's remote bundle dropped or widened its `isWindows()` gate)
  is the unit's one open verification item; the delete verdict for the
  *packaging* patch stands either way per the tracking plan, but the
  user-visible outcome of v3.0.0 vs v2.x hybrid is unverified.
- The verification doc's "Open items" section omits the topbar runtime
  item (it exists only in `.tmp/plans/official-deb-rebase-tracking.md`)
  — a doc-consistency gap, not a factual one.
- Issue #85 → PR #127 causation is inference from matching problem
  statements; PR #127 declares no closing issues.
- Issue #45 → commit `d6ed2c8` (predecessor patch) linkage is inference
  from timing and the issue's closing comment; the commit message cites
  no issue.
- The lukedev45 OmarchyOS partial-render report in the PR #538 thread has
  no traceable resolution (no follow-up issue found; requested diagnostics
  not visible in the thread excerpts examined).
- electron/electron#51396's current state was not checked; it is cited
  only as described in the PR #538 comment.
