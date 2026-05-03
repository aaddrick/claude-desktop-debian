# Runner implementation plan

Tiered triage of the 61 missing test-harness runners across the
76-test matrix. Tier 1 / Tier 2 are within reach this session; Tier
3 is signed-in or multi-step work for a follow-up; Tier 4 is blocked
or out of scope.

Coverage today: 15/76 (~20%). Tier 1 (15 specs) + Tier 2 (16 specs)
land would lift this to roughly 46/76 (~61%) before any Tier 3
work begins.

| Tier | Count | Avg cost | Cumulative coverage if landed |
|------|-------|----------|-------------------------------|
| 1 — file / spawn / argv probes | 15 | 30 min – 1 h | 15 + 15 = 30 / 76 (39%) |
| 2 — single-launch probes | 16 | 2 – 3 h | 30 + 16 = 46 / 76 (61%) |
| 3 — login or multi-step | 22 | 4 – 8 h | 46 + 22 = 68 / 76 (89%) |
| 4 — blocked / out of scope | 8 | — | unchanged |

## Status (post-execution)

**Shipped session 2 (10 new specs):** T10, T16, T23, T25, T26, T38, S10,
S19, S25, S28. Coverage moved from 40/76 (53%) to 50/76 (66%).

Session 2 reclassifications:

- **S28** reclassified from **Tier 2 → Tier 1**. The plan called for
  inspector-eval against `Sbn()` permission classifier with a synthetic
  error string, but `Sbn` is a closure-local in the bundled main process
  — not reachable from `globalThis` and no IPC surface exposes it. The
  shipped runner is a single-regex asar fingerprint that pins the same
  classifier expression (the `"Permission denied" || "Access is denied"
  || "could not lock config file" → "permission-denied"` chain) plus the
  `Failed to create git worktree:` log line. Same drift signal, no
  launch needed.
- **T38** shipped as a **handler-registered probe**, not a no-throw
  invocation. Calling `LocalSessions.openInEditor` directly would
  terminate at `shell.openExternal('vscode://...')` (real editor launch
  + side effect on host) and would also be blocked by the channel's
  origin validation against non-claude.ai senders. Instead, the runner
  inspects `ipcMain._invokeHandlers` for the channel ending in
  `LocalSessions_$_openInEditor`. Documents the channel's
  `$eipc_message$_<UUID>_$_claude.web_$_<name>` framing (UUID is
  build-stable: `c0eed8c9-...`) so a future framing change is visible.
- **T23 tool choice — dbus-monitor, not gdbus monitor.** The plan
  suggested `gdbus monitor --session --dest=org.freedesktop.Notifications`
  but `gdbus monitor --dest <name>` only sees signals OWNED BY that
  destination, not method calls TO it. `Notify` is a method call FROM
  Electron TO the daemon, so `gdbus` cannot observe it. Switched to
  `dbus-monitor` (eavesdrop match rule). Pre-launch checks gate on
  `dbus-monitor` presence + notification-daemon ownership of
  `org.freedesktop.Notifications`.
- **S19 honest-stub note.** The Tier 2 slice is env propagation
  (`extraEnv: { CLAUDE_CONFIG_DIR }` → main-process `process.env`).
  Half 1 (env propagation) is the load-bearing assertion. Half 2
  (resolver-shape echo) is a synthetic re-implementation of `cE()` /
  `Tce()` because those minified symbols are closure-locals — leading
  comment is explicit about the re-implementation status.
- **T25 / T38 / T23 host side effects documented.** T25 may briefly
  open a file manager on the host; T38 deliberately doesn't invoke;
  T23 fires a real notification. Each runner's leading comment
  documents the side effect.

Tier 2 → Tier 2 candidates remaining for a future session: **T31, T32**
(side chat, slash menu — both need a Code-tab session OPEN, not just
the Code tab loaded). **S11, S14** (focus-shifter primitive still
unbuilt — flagged in plan and unchanged).

---

**Shipped session 1 (25 new specs):** T02, T05, T06, T07, T08, T09,
T11, T12, T13, T14a, T14b, S01, S02, S03, S04, S05, S07, S08, S15, S16,
S17, S21, S22, S26, S27. Coverage moved from 15/76 (20%) to 40/76 (53%).

Session 1 reclassifications:

- **T05** shipped as a **Tier 3 delivery probe** (xdg-open →
  `app.on('second-instance', ...)`), not the originally-planned Tier 2
  `app.isDefaultProtocolClient` check — that runtime call is a no-op
  in the harness because `ELECTRON_FORCE_IS_PACKAGED=true` makes
  `app.getName()` resolve to `Claude` instead of `claude-desktop`.
  Real registration is install-time via the `.desktop` file's
  `MimeType=` line. Spec uses `isolation: null` + pre-launch
  `killHostClaude()` so the SingletonLock collision routes the URL.
- **T07** shipped via `createIsolation({ seedFromHost: true })` —
  the topbar IS rendered by claude.ai's authenticated SPA (per
  `docs/learnings/linux-topbar-shim.md`), but the harness's
  hermetic-auth seeding primitive lifts it from Tier 3 to Tier 2.
  T07 is the first spec to exercise `seedFromHost`; it works
  end-to-end (kill host, copy auth allowlist, post-login URL
  reached, topbar DOM probed).
- **T14** intentionally split into **T14a** (asar fingerprint, Tier 1)
  + **T14b** (runtime second-launch focus, Tier 2). Adopt this
  letter-suffix convention for other case-doc tests with both static
  and runtime halves.
- **S20** deferred with an issue tracking the multi-DE DBus channel
  for power-blocker verification (KDE PowerDevil claims the
  `org.freedesktop.PowerManagement.Inhibit` lock; logind
  `systemd-inhibit --list` doesn't see it). Linked from the spec
  index when the issue lands.

**Tier 3 → Tier 2 promotion candidates unlocked by `seedFromHost`:**
T16 (Code tab loads), T26 (Routines page renders), T31 (side chat),
T32 (slash command menu) — each previously deferred for "needs
login" can now ship as `seedFromHost` specs in the T07 pattern.
Login-tests that *write* to the user's account (T22 PR monitoring,
T27 scheduling, T29 worktree creation, T34 OAuth, T36 hooks fire)
remain Tier 3 because the seed is read-only; writes still hit the
real account on close.

Templates referenced below (paths relative to
`tools/test-harness/src/runners/`):

- `H02_frame_fix_wrapper_present.spec.ts` — pure asar/file probe
- `H03_patch_fingerprints.spec.ts` — multi-fingerprint asar probe
- `S09_quick_window_patch_only_kde.spec.ts` — single-fingerprint asar probe
- `S33_electron_version_capture.spec.ts` — bundled-binary metadata read
- `H01_cdp_gate_canary.spec.ts` — short-lived spawn + exit-code probe
- `H04_cowork_daemon_lifecycle.spec.ts` — pgrep delta around launch
- `S12_global_shortcuts_portal_flag.spec.ts` — argv probe with
  launchClaude + `/proc/$pid/cmdline`
- `T01_app_launch.spec.ts` — launchClaude + xprop window probe
- `T03_tray_icon_present.spec.ts` — launchClaude + DBus / SNI walk
- `T04_window_decorations.spec.ts` — launchClaude + xprop frame query
- `T17_folder_picker.spec.ts` — launchClaude + inspector + AX-tree
  click chain (login required)
- `S29_…lazy_create…` / `S31_…submit_reaches_new_chat` — Quick
  Entry: launchClaude + interceptor + ydotool injection
- `S35_…position_persisted_across_restarts` — two-launch with shared
  isolation handle

## Tier 1 — File / spawn / argv probes (~30min – 1hr each)

No app launch needed (or a single short-lived spawn for an exit
code). Existing primitives (`asar.ts`, `argv.ts`, `diagnostics.ts`,
filesystem reads, `execFile` shells) suffice. Cheap wins.

- **T02 — Doctor exit code 0.** Template: `H01` (spawn + exit code) +
  `diagnostics.ts:runDoctor`. Layer: spawn probe. Primitives:
  `lib/diagnostics.ts` (already runs `--doctor` and captures combined
  stdout/stderr). Assertion: spawn `claude-desktop --doctor`, exit
  code === 0, attach stdout for the matrix annotation. `runDoctor`
  currently swallows the non-zero code; extend it to return
  `{ output, exitCode }` and assert in the spec.
- **T13 — Doctor identifies package format correctly.** Template:
  `H01` + `diagnostics.ts:runDoctor`. Layer: spawn probe + stdout
  grep. Assertion: `--doctor` stdout does not contain
  `not found via dpkg (AppImage?)` on a dnf-installed row. Reuses the
  T02 scaffolding; the only delta is a regex on the captured output.
- **S01 — AppImage launches without manual `libfuse2t64`.** Template:
  `H01` (spawn + exit-code probe). Layer: spawn probe. Primitives:
  `child_process.spawn` against the AppImage with `--version` or a
  short-lived launch; capture stderr; expect no
  `libfuse.so.2` mention. Skip on non-AppImage rows. Optional bonus:
  `dpkg -l | grep -i fuse` capture for the diag attachment.
- **S02 — `XDG_CURRENT_DESKTOP=ubuntu:GNOME` doesn't break DE
  detection.** Template: `H03` (multi-fingerprint asar/source probe).
  Layer: file probe. Primitives: read
  `scripts/launcher-common.sh` and `scripts/patches/quick-window.sh`
  from the install path; assert no `==` equality check against
  `XDG_CURRENT_DESKTOP`. Pure shell-source grep — the launcher source
  is shipped alongside the binary on deb/rpm installs (or in the
  worktree on dev). Row gate: Ubu rows.
- **S03 — DEB install pulls runtime deps.** Template: `H02` +
  `H01`. Layer: spawn probe. Primitives: `dpkg-deb -I` on the
  installed package or `apt-cache depends claude-desktop`. Assertion:
  the `Depends:` field is non-empty (or, given S03's case-doc note
  that no `Depends:` line is emitted, capture the field for the
  matrix and mark `✗` against the upstream contract). Row gate: Ubu /
  any deb row.
- **S04 — RPM install pulls runtime deps.** Template: `H02`. Layer:
  spawn probe. Primitives: `rpm -qR claude-desktop`. Same shape as
  S03 — capture and assert the `Requires:` is non-empty. Row gate:
  KDE-W/X, GNOME-W/X, Sway, i3, Niri (any RPM-based row).
- **S05 — Doctor recognises dnf-installed package.** Template: `H01`
  + `diagnostics.ts:runDoctor`. Layer: spawn probe. Primitives:
  `runDoctor` + grep `rpm -qf` install-method line in stdout.
  Assertion: doctor prints an install-method PASS line on RPM-based
  rows (today the entire dpkg-gated block is skipped — the test will
  fail until the rpm branch lands). Row gate: same as S04.
- **S15 — `--appimage-extract` works as documented fallback.**
  Template: `H01` (spawn + exit-code) + `H02` (filesystem assertion
  on the extracted tree). Layer: spawn probe. Primitives:
  `child_process.spawn` of the AppImage with `--appimage-extract`;
  assert exit 0; assert `squashfs-root/AppRun` exists; spawn that
  with `--version` and assert exit 0. Row gate: any AppImage row.
- **S16 — AppImage mount cleans up on app exit.** Template: `H04`
  (pgrep delta around launch + close). Layer: pgrep delta + mount
  probe. Primitives: `mount | grep claude` before launch (baseline),
  after launch (one mount), after `app.close()` + 5s settle (mount
  gone). Reuses launchClaude isolation. Row gate: any AppImage row.
  Borderline Tier 2 (does require a launch); kept here because the
  assertion is purely on `mount(8)` output, no inspector needed.
- **S26 — Auto-update is disabled when installed via apt/dnf.**
  Template: `H03` (fingerprint absence probe). Layer: file probe.
  Primitives: `asar.ts:asarContains` — assert
  `index.js` *contains* `setFeedURL` (upstream code) AND assert no
  patch-applied suppression token (e.g. a `cdd-disable-auto-update`
  marker) is present. As written this is a regression detector that
  *fails* until #567's suppression patch lands. Cheap. Pair with a
  launcher-log scan for `autoUpdater` errors as an attachment.
- **S09 (already landed)** — listed for context, not a new runner.
- **S33 (already landed)** — listed for context, not a new runner.
- **T11 — Plugin install (Anthropic & Partners).** Template: `H03`
  (fingerprint probe). Layer: file probe. Assertion: bundled
  `index.js` contains `installPlugin: attempting remote API install`
  and `installed_plugins.json` strings. This is the file-level
  "install code path is wired" signal — the end-to-end install flow
  with a real plugin click chain is Tier 3 (T33). T11's case-doc
  smoke claim is satisfied by the plumbing being present. Could
  reasonably be argued into Tier 3; kept here because the existing
  case-doc anchors are all upstream-code strings and a pure asar
  probe matches the H02/H03 shape.
- **T14 — Multi-instance behavior (asar fingerprint).** Template:
  `H03`. Layer: file probe. Assertion: `requestSingleInstanceLock`
  + `second-instance` listener strings present in `index.js`. The
  case-doc full assertion (second invocation focuses existing
  window) is Tier 2 — this Tier 1 entry covers the upstream
  contract being in the bundle. Flag in the plan: **the
  case-doc-defined T14 isn't fully testable without two
  launchClaude calls + window-focus detection — split T14 into
  T14a (file probe, here) and T14b (full second-instance behavior,
  Tier 2)** when implementing.
- **S27 — Plugins install per-user.** Template: `H03`. Layer: file
  probe. Assertion: `index.js` contains `cE()` resolving
  `~/.claude` + no system-path string in the plugin install code
  path. Pure asar probe. (The full assertion — actually installing
  a plugin and checking nothing landed in `/usr` — is Tier 3.)
- **S08 — Tray icon doesn't duplicate after `nativeTheme` update.**
  Template: `H03`. Layer: file probe. Assertion: the
  `setImage` + `setContextMenu` in-place fast-path string is in
  `index.js` (injected by `patches/tray.sh:95-231`). Wraps the
  static side of the patch. Runtime tray-rebuild idempotency is
  *already* covered by T03's post-toggle SNI count assertion —
  S08's case-doc claim is fully exercised today, so the static
  fingerprint is the only remaining file-level verification gap.
  Row gate: KDE-W, KDE-X.

## Tier 2 — Single-launch probes (~2-3hrs each)

One `launchClaude()` + inspector attach + an Electron-API or
window-state assertion. Existing primitives suffice. Default
isolation works; signed-in claude.ai is **not** required.

- **T05 — `claude://` URL handler registered.** Template: `T17`
  (inspector eval) + `T01` (window probe). Layer: L1 (inspector).
  Primitives: `inspector.evalInMain` to read
  `app.isDefaultProtocolClient('claude')`. One-line assertion.
  Bonus: spawn `xdg-mime query default x-scheme-handler/claude`
  and capture the result for the diag attachment. The `xdg-open`
  delivery half (does the running app receive the URL?) is a
  separate sub-test — kept Tier 3 because verifying delivery
  needs a second-instance argv path round-trip.
- **T06 — Quick Entry global shortcut registered.** Template:
  `S29` (Quick Entry interceptor) without the ydotool press.
  Layer: L1. Primitives: `inspector.evalInMain` to read the
  `globalShortcut.isRegistered(accelerator)` state for
  `Ctrl+Alt+Space`. Assertion shape is "registration state, not
  delivery"; the unfocused-state shortcut delivery is exercised
  by S29 / S31. Skip rows where ydotool can't drive the press
  (none, since registration assertion doesn't need a press).
- **T07 — In-app topbar renders + clickable.** Template: `T17`
  (renderer eval) — but with **no claude.ai login required**
  because the topbar is in the shell, not behind /login.
  Layer: L1. Primitives: `inspector.evalInRenderer` to query
  `document.querySelectorAll('.topbar button')` (or the AX
  equivalent via `claudeai.ts`). Assertion: five buttons
  present, each has non-zero bounding rect. Click delivery is a
  follow-up. Row gate: rows with PR #538 builds.
- **T08 — Hide-to-tray on close.** Template: `S29` (MainWindow
  state probe) + pgrep. Layer: L1. Primitives:
  `MainWindow.setState('close')` (already in `quickentry.ts`),
  then `MainWindow.getState()` should report `visible: false`,
  then `pgrep -af claude-desktop` should still show our pid.
  Assertion: process alive, window hidden. Reuses `quickentry.ts`
  primitives directly.
- **T09 — Autostart via XDG.** Template: `T17`. Layer: L1.
  Primitives: `inspector.evalInMain` to call
  `app.setLoginItemSettings({ openAtLogin: true })`, then read
  `~/.config/autostart/claude-desktop.desktop` (the wrapper writes
  it via the shim at `frame-fix-wrapper.js:376`). Assert file
  exists, contains `Exec=` line, has valid Desktop-Entry shape.
  Toggle off, assert file gone. Pure file-system observation
  side-stepping XDG login flows.
- **T10 — Cowork integration (asar + spawn delta).** Template:
  `H04` (pgrep delta). Layer: pgrep delta. Primitives: same as
  H04 — `pgrep cowork-vm-service`. The case-doc claim has
  multiple parts; T10 here covers "daemon spawns when needed"
  via H04's existing infrastructure. The "kill the daemon, see
  it respawn" half is Tier 2 too but needs an extra
  pgrep-then-kill-then-poll sequence. Either combine into one
  T10 spec or split into T10a (spawn) + T10b (respawn).
- **T12 — WebGL warn-only.** Template: `T17`. Layer: L1.
  Primitives: `inspector.evalInRenderer` against the main
  webContents to navigate to `chrome://gpu` — actually, that's
  blocked (Electron file: scheme guard). Better: query
  `app.getGPUFeatureStatus()` from main process. Assertion: GPU
  feature status object captured; UI didn't crash. Pure
  Electron-API probe.
- **T14b — Multi-instance second-launch focus.** Template:
  `H04` (pgrep delta) + a second `spawn` call. Layer: spawn
  probe + pgrep delta. Primitives: launchClaude (first), then
  `child_process.spawn` of the launcher a second time, assert
  the second exits ~immediately (existing-instance message)
  and pgrep still shows just the first pid. No inspector
  needed. Borderline Tier 1 — kept here because two launches
  is the load-bearing setup.
- **T26 — Routines page renders (via deeplink).** Template:
  `T17`. Layer: L1. Primitives: launch with
  `--args claude://code` (or whatever deep-link routes to
  routines), wait for `userLoaded`, query the AX tree for the
  Routines sidebar button. **Requires login — promote to
  Tier 3.** Listed here as a candidate; the actual classification
  is T26 → Tier 3. Removed from Tier 2 count.
- **S07 — `CLAUDE_USE_WAYLAND=1` opt-in path works.** Template:
  `S12` (argv + diag log) but with `extraEnv: { CLAUDE_USE_WAYLAND: '1' }`.
  Layer: argv probe + launcher-log scan. Primitives: `argv.ts`
  to confirm `--ozone-platform=wayland` in argv, plus
  `diagnostics.ts:readLauncherLog` to scan for the Wayland-mode
  log line. Row gate: Sway, Niri, Hypr-O, Hypr-N (native-Wayland
  rows).
- **S10 — Quick Entry popup is transparent.** Template: `S29`
  (Quick Entry interceptor, popup state read). Layer: L1.
  Primitives: trigger Quick Entry via ydotool, then
  `inspector.evalInMain` to read `popupWindow.getBackgroundColor()`
  (alpha component) — the construction-time `transparent: true`
  isn't observable through the prototype hook (per CLAUDE.md
  hooking note), but `getBackgroundColor()` returns the runtime
  state. Row gate: KDE-W.
- **S11 — Quick Entry shortcut fires from any focus.** Template:
  `S29`. Layer: L1 + ydotool. Primitives: launch app, focus
  another window (xdotool / ydotool), inject the shortcut, assert
  popup appears. Row gate: GNOME-W, Ubu-W (where the mutter
  XWayland key-grab story matters). **Currently broken on GNOME-W
  per #404 — this is a regression detector, expected to fail until
  the GlobalShortcutsPortal patch lands.**
- **S14 — Global shortcuts via XDG portal work on Niri.** Template:
  `S29`. Layer: L1 + ydotool. Same shape as S11. Row gate: Niri.
  Currently fails per case-doc.
- **S30 (already landed)**, **S29 (already landed)**, etc. listed
  for context.
- **S17 — App launched from `.desktop` inherits shell PATH.**
  Template: `T17`. Layer: L1. Primitives: launch with `extraEnv`
  scrubbing `PATH`, then `inspector.evalInMain` to read the
  process.env.PATH after the shell-path-worker fork completes
  (`index.js:259300` site). Assertion: PATH includes the
  user-shell-profile additions. Tricky bit: the shell-path-worker
  is async; needs a poll. Reuses `retryUntil`.
- **S20 — "Keep computer awake" inhibits idle suspend.** **Deferred —
  see [#569](https://github.com/aaddrick/claude-desktop-debian/issues/569).**
  The case-doc verification path (`systemd-inhibit --list`) doesn't
  work on KDE rows: Electron's `powerSaveBlocker.start('prevent-app-suspension')`
  calls `org.freedesktop.PowerManagement.Inhibit` (PowerDevil), not
  logind's `Inhibit()`, so `systemd-inhibit --list` never sees it.
  Issue #569 tracks the multi-DE DBus channel solution
  (default L1 `isStarted()` + KDE PowerDevil addendum + GNOME
  SessionManager addendum). Grounding probe already covers the L1
  half synthetically.
- **S21 — Lid-close still suspends per OS policy.** Template:
  `H03` (fingerprint absence). Layer: file probe (pure). No
  launch needed — the case-doc anchor is "no `handle-lid-switch`
  string anywhere in `index.js`". `asarContains('index.js', 'handle-lid-switch')`
  must return false. Move to Tier 1 instead. Reclassified.
- **S22 — Computer-use toggle absent or visibly disabled on
  Linux.** Template: `T17` + AX-tree query. Layer: L1.
  Primitives: navigate to Settings → Desktop app → General via
  AX-tree click chain (no claude.ai login needed — settings is
  shell-rendered). Assert the Computer Use toggle is either
  absent or has `disabled: true` on its AX node. Falls back to a
  file-probe Tier 1 if the AX walk is brittle (assert
  `index.js` contains the `qDA = new Set(["darwin", "win32"])`
  fingerprint). **Promote the file-probe form to Tier 1; keep
  the AX-tree form as Tier 3 because the Settings surface may
  itself be claude.ai-side rendering for some panels.**
- **S25 — Mobile pairing survives Linux session restart (token
  storage probe).** Template: `T17` + isolation handle reuse
  (S35 pattern). Layer: L1. Primitives: launchClaude with shared
  isolation, write
  `coworkTrustedDeviceToken` via `safeStorage.encryptString`,
  close, relaunch with same isolation, read it back. Asserts
  the storage key is encrypt/decrypt-stable across restart. The
  end-to-end pairing flow is Tier 3 (needs paired phone); this
  is the Linux-side persistence half.

Net Tier 2 count after reclassifications above: T05, T06, T07, T08,
T09, T10, T12, T14b, S07, S10, S11, S14, S17, S20, S22 (file-probe
form), S25 = **16 specs**.

S21 reclassified to Tier 1 (file-probe only, no launch). Add S21 to
Tier 1 list.

## Tier 3 — Multi-step or login-required (~4-8hrs each)

Defer to follow-up sessions. Each needs either signed-in claude.ai
(`CLAUDE_TEST_USE_HOST_CONFIG=1` + writes to the user's real
account), multi-launch state, or AX-tree click chains against
rendered Code-tab surfaces. Most cluster on the Code tab.

- **T15 — Sign-in completes in embedded webview.** Blocker: live
  OAuth flow with no mock provider. Closest template: `T17`
  (renderer eval) but the `/login/` → token-exchange chain can't
  be driven without real credentials. Could be tested
  destructively against a throwaway test account, but writes to
  a real account.
- **T16 — Code tab loads.** Blocker: needs login.
  Template: `T17`. After login, AX-tree click on the Code tab
  button + assert the `/epitaxy` URL loaded.
- **T18 — Drag-and-drop files into prompt.** Blocker: drag-drop
  injection on Wayland is portal-grabbed; X11 needs xdotool
  drag. Closest template: `T17`. Could be Tier 4 on Wayland;
  Tier 3 on X11 with xdotool.
- **T19 — Integrated terminal.** Blocker: needs login + spawning
  a session. Template: `T17` + IPC probe of
  `LocalSessions_startShellPty`. Login required.
- **T20 — File pane opens and saves.** Blocker: login + Code
  session. Template: `T17` + IPC probe of
  `LocalSessions_writeSessionFile`. Login required.
- **T21 — Dev server preview pane.** Blocker: login + a real
  project + `.claude/launch.json`. Template: `T17`.
- **T22 — PR monitoring via gh.** Blocker: login + open PR +
  authenticated `gh`. Template: `T17`. Could also write a Tier 1
  fingerprint probe for the `gh CLI not found in PATH` string,
  but the case-doc claim is full PR monitoring.
- **T23 — Desktop notifications fire.** Blocker: needs T27 / T22
  / S24 to fire first. Template: DBus monitor on
  `org.freedesktop.Notifications`. Could be Tier 2 if reframed
  as "spawn a notification via `Notification` API and verify it
  reaches the bus" — that's a pure inspector eval. Reframed
  form is Tier 2.
- **T24 — Open in external editor.** Blocker: needs login + a
  Code session + an installed editor. Template: `T17`. Could
  be partially covered Tier 1 by asserting the `Mtt` registry
  fingerprint is in `index.js`, but the case-doc claim is full
  click-chain → editor opens.
- **T25 — Show in Files / file manager.** Blocker: same as T24.
  Closest Tier 2 reframe: inspector-call
  `shell.showItemInFolder('/tmp/x')` directly and assert it
  doesn't throw — that's Tier 2. The case-doc claim is the
  click-chain version.
- **T26 — Routines page renders.** Blocker: login. Template:
  `T17`.
- **T27 — Scheduled task fires and notifies.** Blocker: login
  + creating a real task that writes to the user's account.
  Template: `T17` + DBus notification monitor.
- **T28 — Scheduled task catch-up after suspend.** Blocker:
  login + actual `systemctl suspend` (likely Tier 4 in CI; Tier
  3 on a dev box).
- **T29 — Worktree isolation.** Blocker: login + real Git
  project + multiple parallel sessions. Template: `T17`.
- **T30 — Auto-archive on PR merge.** Blocker: login + PR + 5
  min sweep window. Tier 4-adjacent due to the wait; reframe as
  fingerprint probe for the sweep cadence constants (Tier 1).
- **T31 — Side chat opens.** Blocker: login + Code session.
  Template: `T17`.
- **T32 — Slash command menu.** Blocker: login + Code session.
  Template: `T17`.
- **T33 — Plugin browser.** Blocker: login + the plugin browser
  modal. Template: `T17`. Tier 1 fingerprint probe handles the
  `listMarketplaces` IPC presence; full click-chain through the
  marketplace is Tier 3.
- **T34 — Connector OAuth round-trip.** Blocker: live OAuth +
  browser handoff back. Template: `T17`. Hard to mock.
- **T35 — MCP server config picked up.** Blocker: login + Code
  session + an MCP server fixture. Template: `T17`.
- **T36 — Hooks fire.** Blocker: login + Code session. Template:
  `T17` + filesystem marker check.
- **T37 — `CLAUDE.md` memory loads.** Blocker: login + Code
  session. Template: `T17`.
- **T38 — Continue in IDE.** Blocker: login + IDE installed.
  Template: `T17`. Reframe as
  inspector-eval `LocalSessions.openInEditor(path, …)` and
  assert no throw — that's Tier 2.
- **S06 — URL handler doesn't segfault on native Wayland.**
  Blocker: native-Wayland row + `coredumpctl` correlation.
  Template: spawn URL handler subprocess, monitor for SIGSEGV.
  Could be Tier 2 once a native-Wayland row is wired (the
  harness's `CLAUDE_HARNESS_USE_WAYLAND=1` enables this).
  Reclassify to Tier 2 once a Wayland row is part of the sweep.
- **S18 — Local environment editor persists across reboot.**
  Blocker: requires reboot half. Template: `T17` + isolation
  reuse (S35 pattern) — partial coverage as Tier 2 (across
  app-restart, not host-reboot).
- **S19 — `CLAUDE_CONFIG_DIR` redirects scheduled-task storage.**
  Blocker: login + creating a task. Reframe as Tier 2:
  inspector-eval `Tce()` returns the right path under
  `extraEnv.CLAUDE_CONFIG_DIR`. **Reclassify to Tier 2.**
- **S23 — Dispatch-spawned sessions don't soft-lock.** Blocker:
  paired phone + Dispatch task. Tier 4 unless Dispatch can be
  mocked at the IPC layer (probably can — Tier 3).
- **S24 — Dispatch-spawned Code session appears with badge.**
  Blocker: paired phone. Tier 4 without mock.
- **S28 — Worktree creation surfaces clear error on read-only
  mounts.** Blocker: login + read-only mount fixture.
  Template: `T17` + a `mount -o ro` bind in CI. Reframe Tier 2:
  inspector-eval against `Sbn()` permission-denied classifier
  with a synthetic error message; assert it returns
  `'permission-denied'`. **Reclassify to Tier 2.**

After Tier-3 → Tier-2 reclassifications (S06, S19, S28, T23, T25
reframe, T38 reframe): Tier 3 net count =
T15, T16, T18, T19, T20, T21, T22, T24, T26, T27, T28, T29, T31,
T32, T33 (full form), T34, T35, T36, T37, S18, S23, S25 (full
pairing form) = **22 specs.**

## Tier 4 — Out of scope or blocked

- **T39 — `/desktop` CLI command behavior.** Blocker: this asserts
  the upstream `claude` CLI binary, not the Electron asar. Out of
  harness scope per `cases/README.md` "Anchor scope" — Ambiguous /
  no asar anchor exists. Mark `-` in the matrix.
- **S12 (currently)** — **already a runner** but listed because
  it's a known-failing regression detector by design (will pass
  only after #404 is closed). Keep as Tier 2 land — flagged here
  for awareness.
- **S31 (closed-via-X variant)** — the "close via X" sub-case in
  S31 is already covered by the existing S31 runner under hidden
  state. The "different workspace" variant on Wayland is
  blocked: ydotool can't address-by-workspace and AX-tree
  doesn't reach the compositor. Tier 4 for the workspace half.
- **S32 — Quick Entry submit on GNOME mutter (full repro).**
  Already exists as a runner for the static gate; the full
  Andrej730 stale-`isFocused()` repro requires extra logging
  injection in `h1()`. Tier 4 unless we ship the diagnostic
  patch.
- **S36 — Quick Entry popup falls back to primary display.**
  Blocker: hardware multi-monitor with disconnect. Already
  documented as skip-on-single-monitor. Tier 4 (hardware
  dependent).
- **S37 — Quick Entry popup remains functional after main
  window destroy.** Blocker: project's hide-to-tray override
  makes the destroy path unreachable on Linux without a debug
  build. Tier 4 (architecturally unreachable).
- **T18 (Wayland half)** — drag-drop on Wayland portal-grabbed.
  Already noted; X11 form is Tier 3. Wayland form: Tier 4
  until libei adoption.
- **S11/S12/S14 (delivery-side on portal-grabbed Wayland)** —
  ydotool can't drive portal-grabbed shortcuts. The
  registration-side assertions are Tier 2; the delivery-side
  assertions on portal-grabbed Wayland sessions are Tier 4
  until libei. The case-doc reframes assertion shape so most
  rows are Tier 2; portal-grabbed Wayland rows are Tier 4.
- **T28 — Suspend catch-up.** Tier 4 in CI (real `systemctl
  suspend`); Tier 3 on a dev box with cooperation.

## Primitive gaps to flag

The following Tier 1 / Tier 2 items hint at a missing primitive or
a primitive that needs a small extension:

- **`runDoctor` should expose exit code.** T02 / T13 / S05 all need
  `{ output, exitCode }`. Today's implementation swallows the code.
  One-line lib/diagnostics.ts edit.
- **AppImage detection helper.** S01 / S15 / S16 need to know "is
  the install an AppImage". Today the test would spawn the
  launcher and look at mount output; a `lib/install.ts:detectFormat()`
  that returns `'deb'|'rpm'|'appimage'|'unknown'` from probing the
  install paths would centralize this.
- **`mount(8)` parser.** S16 needs `mount | grep claude`-style
  observation; nothing under `lib/` does that today. Trivial
  `child_process.exec` wrapper, but worth its own file
  (`lib/mounts.ts`) for reuse by future install-path tests.
- **systemd-inhibit list parser.** S20 needs to parse
  `systemd-inhibit --list` output to find the Claude-owned
  `idle:sleep` lock. New `lib/systemd.ts` module — also useful
  for future power-state tests (T28).
- **DBus notification monitor.** T23 / T27 need to observe
  `org.freedesktop.Notifications`. The existing `lib/dbus.ts`
  does `getConnectionPid` only; a new `lib/notifications.ts`
  with `monitorNotifications(predicate)` would be a clean
  extension.
- **xdotool / ydotool focus-stealing.** S11 / S14 need to
  focus another app before injecting the shortcut. Today
  `quickentry.ts` injects the shortcut but doesn't shift
  focus. Add `lib/input.ts:focusOtherWindow()` (X11
  `xdotool` shell-out; Wayland: skip).
- **Source-tree introspection (not just app.asar).** S02 / S26
  reference `scripts/launcher-common.sh` and other repo files
  not in the asar. A `lib/repo.ts:readRepoFile(path)` that
  resolves against a known repo root would give the file probes
  a clean entry. For an installed-binary sweep, the launcher
  source is shipped under `/usr/lib/claude-desktop/scripts/`
  on deb/rpm; for the dev tree, it's the worktree itself. The
  helper would probe both.
- **Plugin install side-channel.** T11 (full form, not the
  fingerprint probe) needs to verify
  `~/.claude/plugins/installed_plugins.json` after a click chain.
  Tier 3 only — flagged for later.
- **Multi-monitor helper.** S36 — out of scope (Tier 4 hardware
  dependent), but if it ever becomes tractable, a
  `lib/displays.ts` mocking `screen.getAllDisplays()` would be
  the entry.

## Open questions for the parent agent

- **T11 / T14 split.** The case-doc T11 / T14 conflate "code path
  exists in asar" with "click chain works end-to-end". The plan
  splits each into a Tier-1 fingerprint probe and a Tier-3 full
  flow. If the parent prefers single-spec coverage, T11 / T14
  drop entirely from Tier 1 and live only in Tier 3.
- **Reframe-to-Tier-2 calls.** T23 / T25 / T38 / S18 / S19 / S28
  are written here as Tier 2 *reframes* of Tier 3 case-doc
  claims. Each reframe trades end-to-end fidelity for an
  IPC-shaped assertion that's testable without login. Reasonable
  policy is "land both" — the Tier 2 reframe today, the Tier 3
  full flow when login is wired. Confirm before fanning out.
- **Wayland row strategy.** Several Tier 3 entries collapse to
  Tier 2 on a Wayland row (S06 segfault, S07 opt-in flag), and
  several Tier 2 entries collapse to Tier 4 on portal-grabbed
  Wayland (S11/S14 delivery half). The plan classifies for the
  default X11 row. If the sweep is run with
  `CLAUDE_HARNESS_USE_WAYLAND=1`, several reclassifications
  apply.
- **The "pure file probe vs needs-launch" line on multi-part
  case-docs.** T07 / T10 / S22 each have a load-bearing static
  fingerprint AND a load-bearing runtime click. The plan picks
  the static form for Tier 1 / Tier 2 and notes the runtime
  form's Tier 3 cost separately. If the parent wants one spec
  per case-doc test, a few reclassifications.
- **CDP gate side-effect on T17.** T17 runs against a
  signed-in host config today; without
  `CLAUDE_TEST_USE_HOST_CONFIG=1` it cleanly skips. Several Tier
  3 specs follow this pattern. The matrix's "skip" cell semantics
  for these tests need a sweep-runner convention — probably
  `-` rather than `?` for "host config required, not provided".
