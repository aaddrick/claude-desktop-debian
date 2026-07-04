# Dossier: Frame-fix wrapper (`frame-fix-wrapper.js` + `frame-fix-entry.js`)

Unit: the runtime `require('electron')` interception layer — `scripts/frame-fix-wrapper.js`,
the generated `frame-fix-entry.js`, and the injection/`package.json` main-swap code in
`scripts/patches/app-asar.sh` on `main` — including the titlebar modes
(`CLAUDE_TITLEBAR_STYLE`) and the Linux autoUpdater no-op Proxy.

## Mechanism

Unlike every other unit in the legacy suite, this one performs **no sed edits on the
minified bundle** at all (since commit `0f776a1`, which removed the original
`frame:false→true` seds — see Revision history). It is pure runtime interception,
injected at build time:

**Build-time injection** (`main:scripts/patches/app-asar.sh`, inside `patch_app_asar`):

- Copies `scripts/frame-fix-wrapper.js` into `app.asar.contents/frame-fix-wrapper.js`.
- Generates `frame-fix-entry.js` via heredoc (`frame-fix-entry.js` is **not** a repo file
  on main; it exists only as this heredoc):

  ```
  cat > app.asar.contents/frame-fix-entry.js << EOFENTRY
  // Load frame fix first
  require('./frame-fix-wrapper.js');
  // Then load original main
  require('./${original_main}');
  EOFENTRY
  ```

- Swaps the asar's entry point via node: `pkg.originalMain = pkg.main;
  pkg.main = 'frame-fix-entry.js';` (the "package.json main swap").
- A comment in the same function states the design: "BrowserWindow frame/titleBarStyle
  patching is handled at runtime by frame-fix-wrapper.js via a Proxy on
  require('electron'). No sed patches needed."

**Runtime interception** (`main:scripts/frame-fix-wrapper.js`, 997 lines):

- Monkey-patches `Module.prototype.require`; when `id === 'electron'` it builds its
  patches once (guarded by `if (!PatchedBrowserWindow)` — the idempotency mechanism)
  and returns `new Proxy(result, { get(...) ... })` over the electron module. The Proxy
  is required because "electron's exports use non-configurable getters, so we cannot
  directly reassign module.BrowserWindow" (comment at the Proxy return; rationale in
  commit `0f776a1`).
- Proxy `get` traps (lines ~928–993):
  - `BrowserWindow` → `PatchedBrowserWindow` (a `class BrowserWindowWithFrame extends
    OriginalBrowserWindow` with a heavily patched constructor).
  - `Menu` → nested Proxy replacing `setApplicationMenu` (menu-bar hiding + hidden F11
    `togglefullscreen` accelerator, "Fixes: #580"; hide-all comment cites "Fixes: #321").
  - `powerSaveBlocker` (Linux) → logging shim; `CLAUDE_KEEP_AWAKE=0` suppresses
    `start()` entirely ("See #605").
  - `autoUpdater` (Linux) → `autoUpdaterNoop`, a chainable Proxy: every property access
    returns `function chainNoop() { return autoUpdaterNoop; }` so
    `.on(...).once(...).setFeedURL(...).checkForUpdates()` is harmless; `getFeedURL`
    returns `''`; `then`/`catch`/`finally`/`Symbol.toPrimitive`/`Symbol.iterator` return
    `undefined` so V8 doesn't treat it as a thenable (silent-await-hang trap) or coerce it
    ("See #567").
- **Popup detection** — `isPopupWindow(options)`:
  ```
  if (options.frame === false) return true;                       // Quick Entry
  if ('parent' in options) return false;                          // Hardware Buddy child modal
  if ((options.titleBarStyle === '' || options.titleBarStyle === 'hiddenInset')
      && !options.minWidth) return true;                          // About
  ```
  `minWidth` excludes the main window; popups stay frameless, main windows get frames.
- **Titlebar modes** — `CLAUDE_TITLEBAR_STYLE` ∈ `hybrid` (default) / `native` /
  `hidden`. `hybrid` and `native` force `options.frame = true` and delete the
  macOS/Windows-only `titleBarStyle`/`titleBarOverlay`; `hybrid` pairs with the wco-shim
  (separate unit) for the in-app topbar; `hidden` keeps `frame:false` + a
  `titleBarOverlay` object and is documented in-file as "BROKEN ON LINUX X11" (Chromium
  implicit drag region; see `docs/learnings/linux-topbar-shim.md`).
- **Everything else that accreted into the constructor / app hooks** (each with a
  `Fixes:` comment in the file): `process.resourcesPath` correction from `__dirname`
  (Nix); `CLAUDE_MENU_BAR` auto/visible/hidden with boolean aliases; Linux scrollbar CSS
  injection; WCO diagnostic probe; focused-window Ctrl+Q ("Fixes: #399");
  close-to-tray with `CLAUDE_QUIT_ON_CLOSE=1` opt-out ("Fixes: #448") plus an active
  `app.quit()`-on-close branch for the opt-out ("Fixes: #623"); Alt-keyup menu-bar toggle
  ("Fixes: #630"); `fixChildBounds`/jiggle machinery for stale Chromium layout caches
  ("Fixes: #239", "Fixes: #323", "Fixes: #84"); `flashFrame(false)` on focus
  ("Fixes: #149"); sloppy-WM `webContents.focus()` suppression ("Fixes: #416");
  XDG Autostart shim for `get/setLoginItemSettings` ("Fixes: #128"); in-place-upgrade
  watcher on `app.asar` ("Fixes: see PR #564").

## Origin

- **First commit:** `7882635` — "feat: Add native window decorations support for Linux",
  2025-11-04, author **speleoalex** (external contributor). Merged 2025-11-05 via
  `281847b` = **PR #127** ("feat: Add native window decorations support for Linux").
- **Form at origin:** the wrapper was a heredoc embedded in `build.sh` (`EOFFIX` block),
  alongside two other layers the wrapper later absorbed or that were later removed:
  (1) sed passes over every `.vite/build/*.js` replacing `frame:false`/`frame:!0`/
  `frame:!1` with `frame:true` and normalizing `titleBarStyle` to `""`, and
  (2) a `--disable-features=CustomTitlebar` Electron flag in the launchers. The
  `frame-fix-entry.js` heredoc and the `pkg.main = 'frame-fix-entry.js'` swap are
  original to this commit.
- **Why:** the repackage then shipped the app.asar extracted from the **Windows**
  installer, whose main window was created `frame:false` with a custom titlebar. PR #127's
  body states the problem directly: "Claude Desktop on Linux displays windows without
  native window manager decorations (title bar, borders, minimize/maximize/close
  buttons)." Commit message: "This fixes the issue where Claude Desktop windows appeared
  without borders or native decorations on Linux window managers. Tested on: KDE Plasma
  (Wayland)." No pre-existing GitHub issue was found linked to PR #127 (searched; the PR
  body is the problem statement).

## Revision history

Substantive changes only, in date order (SHA · date · what · why):

1. `4174c20` · 2026-01-20 · Added `autoHideMenuBar: true` to the constructor options,
   `setMenuBarVisibility(false)` after window creation, and the
   `Menu.setApplicationMenu` interception (re-hide the menu bar on all windows after
   the app's async menu set) to the wrapper heredoc in `build.sh` — the origin of the
   Menu-interception layer (23 insertions incl. `module.Menu.setApplicationMenu =
   function(menu)`). Why (commit message): "The app calls Menu.setApplicationMenu()
   asynchronously after window creation, which causes the menu bar to appear even when
   we hide it in the BrowserWindow constructor." Fixes #155 ("Menu bar visible on
   Linux after v1.2.1 (X11/XWayland mode)"); landed via PR #169, merged 2026-01-21
   (merge `fe79297`).
2. `4bf5986` · 2026-01-22 · Extracted the heredoc to `scripts/frame-fix-wrapper.js`
   (also claude-native stub). Why: "Part of #179" (refactor build scripts for
   maintainability), per commit message.
3. `83cbb9a` · 2026-02-14 · Major rework by **vboi** (PR #228): popup/Quick Entry
   detection (#223), scrollbar CSS injection, persistent menu-bar hiding (#172,
   building on `4174c20`'s interception), KDE attention-flash fix (#149), content
   resize fix (#84); commit trailer "Fixes #84,
   #149, #172, #223, #226" (#226 was the launcher-side Wayland part of the same PR, not
   this file). Why: Quick Entry was getting an unwanted frame from the blanket
   `frame:true` (issue #223), plus the other Linux UX bugs listed.
4. `befc757`…`75841f0` series · 2026-02-16 · Review-findings arc for PR #228 (issue
   #231, landed as PR #232): popup detection keyed on `frame:false` intent, `skipTaskbar`
   removed (`befc757`); `setTimeout(50ms)` instead of `setImmediate` for the resize hack
   (`f723de4`); consolidated ready-to-show handlers and guarded popup-unsafe patches
   (`5785076`); `isDestroyed` guard in `setApplicationMenu` (`0fc8286`). Why: stated in
   the commit subjects — code-review findings from PR #228.
5. `99a7117`, `d97f643` · 2026-02-16 · Popup-anchor churn: detect Quick Entry by
   `titleBarStyle:'hidden'`, then Quick Entry/About by `titleBarStyle:''` without
   overlay. Why (inference from subjects): matching the actual upstream window options
   as they were understood better the same day.
6. `0f776a1` · 2026-02-16 · **Architectural pivot: Proxy-based interception.** Replaced
   direct `module.BrowserWindow` assignment (which "silently fails" — electron's export
   is a non-configurable getter) with the module-level Proxy; detected popups by
   `titleBarStyle:''` without `minWidth`; **removed the sed patches from build.sh**
   ("the wrapper now handles all frame/titleBarStyle modifications at runtime"); built
   patches once and reused. All quoted from the commit message.
7. `82efbfa` · 2026-02-17, `7adbdae` · 2026-02-18, `8bf10dc` · 2026-02-19 · Resize/
   layout-cache saga for #239: debounced jiggle → `getContentBounds()` monkey-patch →
   replaced with direct child `setBounds()` (the monkey-patch caused drag-resize jitter,
   per the surviving in-file comment "Instead of monkey-patching getContentBounds()
   (which causes drag resize jitter at ~60Hz)").
8. `0b56a2f` · 2026-02-23 · `CLAUDE_MENU_BAR` env var (auto/visible/hidden). Why:
   "Fixes #250" — layout shift on KDE when accidental Alt presses show the menu bar.
   Contributed by **noctuum** (credited in README Acknowledgments).
9. `573f052` · 2026-02-26 · `process.resourcesPath` correction derived from the asar's
   location. Why (commit message): Nix builds put Electron in a separate store path so
   `resourcesPath` pointed at the wrong directory.
10. `07c1388` · 2026-02-28 · `CLAUDE_MENU_BAR` input validation, docs, `--doctor`
    integration; `e1dbbc2` + `9b4ac63` · 2026-03-19 · boolean aliases (0/1/true/false…).
11. `2cfc6a8`, `062f460`, `f62b553` · 2026-03-22 · Tiling-WM workspace-switch handling
    (#323): resize-event handling, then debounced same-size jiggle, then the `armPair`
    helper consolidation. Why: "Does not resize when using hyprland" (#323).
12. `c429cfb` · 2026-04-01 · Alt menu toggle fixed in 'auto' mode (force-hide was
    overriding Electron's native toggle) + **global** Ctrl+Q shortcut. Why (commit
    message): give GNOME users quit paths without a tray icon (context: issue #321,
    "no clean shutdown or quit option"; the in-file `Fixes: #321` tag sits on the
    setApplicationMenu interceptor).
13. `4e2b9d7` · 2026-04-21 · PR #484: Ctrl+Q scoped to the focused window via
    `before-input-event`, replacing the globalShortcut. Why: the global grab stole
    Ctrl+Q from every app on the system (#399, "System-wide Ctrl+Q on Linux") and, on
    non-QWERTY layouts, swallowed whatever keysym sits at the physical Q position —
    Ctrl+A on AZERTY (#474, "Ctrl+A not working anymore globally with app running").
    Commit trailers: "Fixes: #399" and "Fixes: #474".
14. `8530342` · 2026-04-28 · PR #451: close-to-tray (hide on close, `before-quit` arms
    `_quittingIntentionally`), `CLAUDE_QUIT_ON_CLOSE=1` opt-out. Why: #448 — app quit on
    last-window-close broke in-app schedulers (reported by @lizthegrey per CHANGELOG).
15. `412b267` · 2026-04-28 · PR #450: `app.get/setLoginItemSettings` routed through XDG
    Autostart. Why: #128 — Electron `openAtLogin` is a no-op on Linux
    (electron/electron#15198), so "Run on startup" never persisted.
16. `5c8191e` · 2026-05-01 · PR #538: **`CLAUDE_TITLEBAR_STYLE` machinery** (hybrid/
    native/hidden, default hybrid) + WCO diagnostics + console mirror. Why (commit
    message): the upstream `frame:false` + WCO config has unclickable topbar buttons —
    a Chromium-level implicit drag region for frameless windows with "no Electron-API
    knob"; hybrid = native frame + wco-shim UA spoof. Investigation in
    `docs/learnings/linux-topbar-shim.md`.
17. `b8e1a1f` · 2026-05-05 · PR #564: in-place package-upgrade watcher on `app.asar`
    (fs.watch on the parent dir, notification offering restart). Why (commit subject):
    post-swap window loads mix v(N+1) assets with v(N) code in memory.
18. `920c2be` · 2026-05-07 · Sloppy-WM `webContents.focus()` suppression hooked at
    `web-contents-created`. Why: #416 — every hover raised the window under
    focus-follows-mouse (EWMH `_NET_ACTIVE_WINDOW` = focus-and-raise; tracks
    electron/electron#38184). Landed via PR #589; follow-up `d54efca` · 2026-05-24 added
    the `restore` event to the `_lastShownAt` tracking and documented the deferred-focus
    gap ("#416 review notes" in-file).
19. `d5a4104` · 2026-05-09 · **autoUpdater no-op Proxy** (#567). Why (commit message):
    the bundled app sets a feed URL `api.anthropic.com/api/desktop/linux/...` when
    `app.isPackaged` (forced true by the launcher's `ELECTRON_FORCE_IS_PACKAGED`);
    today harmless only because Electron's Linux autoUpdater is unimplemented — a
    "happy accident" to defend against.
20. `8796aa2` · 2026-05-14 · Masked `then`/`catch`/`finally`/`Symbol.toPrimitive`/
    `Symbol.iterator` on the no-op Proxy. Why (commit message): V8's thenable check
    called `chainNoop` as `then(resolve, reject)` → `await` hung forever; verified in
    node:20-alpine.
21. `d632fdb` · 2026-05-14 · Popup detection extended to `titleBarStyle:'hiddenInset'`
    + `'parent' in options` early-return. Why: upstream migrated the About window from
    `titleBarStyle:""` to `"hiddenInset"`, so `isPopupWindow()` stopped matching it and
    About broke (#481, "About This App dialog shows minified JavaScript error"); "Picks
    up @Hayao0819's #489" and guards the Hardware Buddy child modal (all per commit
    message; `b017c72` credits Hayao0819 in the README). aaddrick pushed this rework
    onto Hayao0819's `fix/about-window-hiddenInset` branch, so it landed **via PR #489
    itself** (merge `25abb00`, 2026-05-15; the merge's second parent is `d632fdb`).
22. `6eca4da` · 2026-05-18 · Active `app.quit()`-on-close when `CLAUDE_QUIT_ON_CLOSE=1`.
    Why: #623 — the bundled main-process close handler hardcodes preventDefault+hide on
    non-Windows, so the opt-out alone did nothing; rides upstream's own quit-in-progress
    guard. Contributed by **phelps-matthew** via PR #624 (per README/CHANGELOG credit).
23. `a32e1aa` · 2026-05-24 · Hidden View submenu with F11 `togglefullscreen`
    accelerator. Why: #580 — Linux has no OS-level fullscreen trigger equivalent to
    macOS's green button.
24. `d6fc044` · 2026-05-24 · PR #642: menu-bar toggle moved to Alt **keyup** with a
    per-window chord tracker. Why: #630 — keydown toggling grabbed focus before
    Alt+Shift (language switch) / Alt+F4 could complete.
25. `a470b30` · 2026-05-24 · PR #645: powerSaveBlocker logging shim +
    `CLAUDE_KEEP_AWAKE=0`. Why: #605 — upstream's `keepAwakeEnabled` has no lifecycle
    management on Linux; the inhibitor fires at init and never releases, blocking
    suspend/screensaver.
26. `76a5a21` · 2026-05-25 (PR #648) and `e7e6475` · 2026-05-27 · `StartupWMClass`
    alignment in the autostart entry (`buildAutostartContent` derives it from
    `app.name`); part of the repo-wide WM_CLASS centralization.

## Related issues and PRs

| # | Kind | Title | State | Role |
|---|------|-------|-------|------|
| 127 | PR | feat: Add native window decorations support for Linux | merged | Origin — created the wrapper + entry + main swap (speleoalex) |
| 155 | issue | Menu bar visible on Linux after v1.2.1 (X11/XWayland mode) | closed | Motivated the Menu-interception layer's origin — `autoHideMenuBar`, post-create `setMenuBarVisibility(false)`, `Menu.setApplicationMenu` interception (`4174c20`) |
| 169 | PR | fix: hide menu bar on Linux by intercepting setApplicationMenu | merged | Landed `4174c20` (Fixes #155), merged 2026-01-21 (merge `fe79297`) |
| 179 | issue | Refactor build scripts for maintainability and readability | closed | Motivated extraction of the heredoc to `scripts/frame-fix-wrapper.js` (`4bf5986`) |
| 223 | issue | Quick Entry window shows unwanted frame on KDE Plasma Wayland | closed | Regression caused by the blanket `frame:true`; motivated popup detection (`83cbb9a`) |
| 172 | issue | Menu bar still visible despite disabling flags on Linux Mint (Electron) | closed | Motivated making the menu-bar hiding persistent in `83cbb9a` ("persistent menu bar hiding (#172)"); the interception layer itself originated in `4174c20` (#155) |
| 84 | issue | Content not sized correctly for window unless resized | closed | Motivated the ready-to-show 1px jiggle (`83cbb9a`) |
| 149 | issue | KDE Plasma 6 + Wayland: Window demands attention on Alt+Tab… | closed | Motivated `flashFrame(false)` on focus (`83cbb9a`) |
| 226 | issue | AppImage crashes on Niri compositor due to missing Wayland flags | closed | Fixed by the launcher half of PR #228 (same PR, outside this unit) |
| 228 | PR | fix: improve Linux UX - popup detection, functional stubs, Wayland compositor support | merged | Major rework of the wrapper (vboi) |
| 231 | issue | Address review findings from PR #228 | closed | Review of #228; drove the 2026-02-16 fix series |
| 232 | PR | fix(issue-231): address review findings from PR #228 | merged | Landed the review-feedback series incl. the Proxy pivot context |
| 239 | issue | WebContentsView layout broken on resize and login/logout transitions | closed | Motivated the child-setBounds layout-cache fix (`8bf10dc`) |
| 250 | issue | feat: allow users to control menu bar visibility via CLAUDE_MENU_BAR env var | closed | Motivated `CLAUDE_MENU_BAR` (`0b56a2f`, noctuum) |
| 321 | issue | Orphaned processes after closing the app — no clean shutdown or quit option | closed | Motivated quit accessibility (Alt toggle + Ctrl+Q, `c429cfb`); tagged `Fixes: #321` in-file |
| 323 | issue | Does not resize when using hyprland | closed | Motivated tiling-WM resize/jiggle handling (`2cfc6a8`, `062f460`) |
| 399 | issue | System-wide Ctrl+Q on Linux | closed | Regression caused by `c429cfb`'s globalShortcut (Ctrl+Q stolen from every app); fixed by PR #484 |
| 474 | issue | [bug]: Ctrl+A not working anymore globally with app running | closed | Second regression report against `c429cfb`'s globalShortcut (keysym at the physical Q position swallowed on AZERTY); fixed by PR #484 |
| 484 | PR | fix(shortcut): scope Ctrl+Q to focused window, not system-wide | merged | Fixed #399 and #474 (`4e2b9d7`, trailers "Fixes: #399" + "Fixes: #474") |
| 448 | issue | Linux: app quits when last window closed; breaks in-app schedulers… | closed | Motivated close-to-tray (PR #451) |
| 451 | PR | fix(lifecycle): hide main window to tray on close, Linux | merged | Added CLOSE_TO_TRAY + `CLAUDE_QUIT_ON_CLOSE` (`8530342`) |
| 623 | issue | [bug]: CLAUDE_QUIT_ON_CLOSE=1 leaves app alive — bundled close handler still hides | closed | Regression report against #451's opt-out; fixed by PR #624 |
| 624 | PR | fix: actively quit on close when CLAUDE_QUIT_ON_CLOSE=1 (#623) | merged | phelps-matthew's fix, landed as `6eca4da` |
| 128 | issue | Run on startup setting not saved | closed | Motivated the XDG Autostart shim (PR #450) |
| 450 | PR | fix(autostart): route openAtLogin through XDG Autostart on Linux | merged | Landed the autostart shim (`412b267`) |
| 538 | PR | feat(linux): hybrid titlebar mode for clickable in-app topbar | merged | Added `CLAUDE_TITLEBAR_STYLE` hybrid/native/hidden (`5c8191e`) |
| 564 | PR | feat(lifecycle): notify and offer restart on in-place package upgrade | merged | Added the upgrade watcher (`b8e1a1f`) |
| 416 | issue | Window raises to foreground on mouse hover with sloppy/focus-follows-mouse mode | closed | Motivated the `webContents.focus()` suppression (`920c2be`) |
| 589 | PR | fix(frame-fix): skip redundant webContents.focus() under sloppy WMs (#416) | merged | Landed/refined the #416 fix (`d54efca` follow-up) |
| 567 | issue | Disable Electron auto-updater on Linux (currently relies on a happy accident) | closed | Motivated the autoUpdater no-op Proxy (`d5a4104`, `8796aa2`) |
| 481 | issue | [BUG] "About This App" dialog shows minified JavaScript error instead of version info | closed | Regression from upstream `titleBarStyle` migration breaking `isPopupWindow()`; fixed by `d632fdb` |
| 489 | PR | fix: handle upstream titleBarStyle change for About window | merged | Hayao0819's fix; aaddrick pushed the rework commit `d632fdb` onto the PR branch (preserving Hayao0819's diagnosis and logic extension, per `d632fdb`'s message) and merged it 2026-05-15 as `25abb00` — the merge's second parent is `d632fdb` itself |
| 580 | issue | [feature]: Fullscreen support (F11) | closed | Motivated the hidden F11 menu item (`a32e1aa`) |
| 630 | issue | [bug]: Alt key press focuses menu bar on keydown instead of keyup | closed | Motivated the Alt-keyup toggle (PR #642) |
| 642 | PR | fix: toggle menu bar on Alt keyup, not keydown | merged | Fixed #630 (`d6fc044`) |
| 605 | issue | [bug]: Electron process holds sleep inhibitor indefinitely, preventing suspend and screensaver | closed | Motivated the powerSaveBlocker shim (PR #645) |
| 645 | PR | fix: add powerSaveBlocker logging shim and CLAUDE_KEEP_AWAKE=0 escape hatch | merged | Fixed #605 (`a470b30`) |
| 648 | PR | fix: align WM_CLASS and StartupWMClass to claude-desktop across all formats | merged | Touched the autostart `StartupWMClass` in the wrapper (`76a5a21`, then `e7e6475`) |

## Learnings

- `docs/learnings/test-harness-electron-hooks.md` — records that constructor-level
  `BrowserWindow` wraps installed by test harnesses are **silently bypassed** because
  "`scripts/frame-fix-wrapper.js` returns the electron module wrapped in a `Proxy`" whose
  get-trap returns `PatchedBrowserWindow` from a closure; only prototype-method hooks
  survive. It explicitly warns: "If frame-fix-wrapper is removed (or stops returning a
  Proxy), the [hook contract changes]" — directly relevant to the rebase deletion.
- `docs/learnings/linux-topbar-shim.md` — the investigation behind the titlebar modes:
  why upstream `frame:false` + WCO has unclickable buttons on X11 (Chromium implicit
  drag region), the mode table (`hybrid` default → "clicks work"), resolved 2026-04-29.
- `docs/learnings/official-deb-rebase-verification.md` — the patch-necessity matrix
  rows for this unit (quoted below).
- Also referenced heavily by `docs/testing/cases/tray-and-window-chrome.md` and
  `docs/testing/automation.md` (code anchors into the wrapper for test cases T04 etc.).

## Fate under the official-deb rebase

**Verdict (matrix rows, quoted verbatim from
`docs/learnings/official-deb-rebase-verification.md`):**

> | `frame-fix-wrapper.js` | **delete** | The only `frame:!1` sites are the Quick Entry popup and two transparent overlay windows — intentionally frameless on every platform. The main window omits `frame` (system frame). |

> | autoUpdater no-op Proxy | **delete** | Updater bootstrap early-returns with `apt_channel_pending`; "Check for updates" opens the browser. |

**Byte-level evidence:** verified against official 1.17377.2 (audited 2026-07-02).
`tools/patch-necessity-audit.sh`'s `probe_frame_fix()` (lines 114–126) counts
`frame:\s*!1` in the official `index.js` and reports `not-needed` **only at zero
hits**; any nonzero count yields `check` ("frame:!1 occurs Nx — confirm Linux
reachability") — the probe has no popup-allowlist logic. Since the matrix row itself
says `frame:!1` sites exist (Quick Entry + two overlays), the tool would have emitted
`check` here, and the matrix's popup-reachability judgment (those windows are
intentionally frameless on every platform) is a **manual verification recorded in the
doc, not a mechanical output of the tool**. The autoUpdater probe greps for
`apt_channel_pending\|apt channel not yet live` and reports "updater disabled at source
(apt_channel_pending)". The official main window omits `frame` entirely, so Linux gets
the system frame natively — the wrapper's core purpose (and the whole titlebar-mode
apparatus plus the wco-shim, whose matrix row is also **delete**: "Never frameless, no
UA spoof") is moot.

**How the rebase branch handles it now (working tree, branch `rebase/official-deb`):**

- `scripts/frame-fix-wrapper.js` (997 lines) was deleted in commit `d9cef9e`
  ("feat(rebase): Phases 1+2"), whose message lists among the "11 condemned patches
  deleted: frame-fix wrapper (incl. the autoUpdater no-op)". No `frame-fix-entry.js`
  heredoc or `pkg.main` swap exists anymore.
- `scripts/patches/app-asar.sh` on the working tree is a thin orchestrator with
  `active_patches=(patch_quick_window patch_org_plugins_path)` — the two survivor
  candidates only. When the array is empty the official `app.asar` ships byte-identical
  ("patch-zero"). No entry-point rewrite of any kind: the official `package.json` `main`
  is untouched.
- `scripts/doctor.sh` `_check_legacy_env()` (around line 771) warns when
  `CLAUDE_TITLEBAR_STYLE`, `CLAUDE_MENU_BAR`, or `CLAUDE_KEEP_AWAKE` are set: "$var is
  set but no longer honored since the v3.0.0 rebase onto the official build".
- The launcher (`scripts/launcher-common.sh`) execs the official ELF; no wrapper env
  plumbing remains (no `frame-fix` hits anywhere under `scripts/` on the working tree).

**Consequences / open items carried by the deletion** (behavioral surface the wrapper
provided that has no matrix row of its own): the ~20 accreted Linux fixes ride along
with the deletion — menu-bar modes, close-to-tray opt-out (`CLAUDE_QUIT_ON_CLOSE`),
XDG autostart shim (#128), tiling-WM layout jiggles (#239/#323/#84), sloppy-WM focus
suppression (#416), keep-awake escape hatch (#605), F11 (#580), Alt-keyup toggle
(#630), upgrade watcher (#564). The rebase's position (per the matrix's patch-zero
contract, "the default verdict for any patch is delete") is that these must re-justify
themselves against the official build individually; none is currently wired.

## Gaps

- **No motivating issue for the origin PR #127 was found** — GitHub search for
  decoration/frame issues predating 2025-11-04 returned nothing linked; PR #127's body is
  the primary problem statement.
- **I did not re-run the byte-level audit myself.** The verdict evidence is the matrix
  doc (audited 2026-07-02 against 1.17377.2) plus the probe logic in
  `tools/patch-necessity-audit.sh`; I verified the probes exist and what they grep, not
  their output against a fresh extraction.
- **Whether the accreted fixes reproduce on the official build is unverified per-item.**
  The matrix only rules on the frame core and the autoUpdater no-op. E.g. whether #416
  (hover-raise), #605 (sleep inhibitor), #128 (openAtLogin persistence) or #630
  (Alt-keydown) recur in the official 1.17377.x bundle has no recorded byte- or
  runtime-level check. #623's analysis says the bundled code hides-on-close on all
  non-Windows platforms, which — if still true in the official build — makes
  close-to-tray native but removes the `CLAUDE_QUIT_ON_CLOSE=1` escape hatch with no
  replacement.
- **Doctor's legacy-env warning list omits `CLAUDE_QUIT_ON_CLOSE`** (only
  `CLAUDE_TITLEBAR_STYLE`, `CLAUDE_MENU_BAR`, `CLAUDE_KEEP_AWAKE` are checked in
  `scripts/doctor.sh` `_check_legacy_env`). Whether that omission is intentional is not
  recorded anywhere I found.
- **Working-tree docs are stale by design**: `README.md` (Acknowledgments) and
  `CHANGELOG.md` still describe `CLAUDE_QUIT_ON_CLOSE`/`CLAUDE_MENU_BAR` behavior, and
  `docs/testing/cases/*.md` still anchor into the deleted wrapper — the Phase 6 docs arc
  had not landed as of this dossier.
- Attribution of the 2026-02-16 review-series commits to PR #232 is based on commit
  subjects ("address code review feedback for PR #232", "fix(issue-231)…"); I did not
  diff the PR head against the commits individually.
