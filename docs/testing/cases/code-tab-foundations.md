# Code Tab — Foundations

Tests covering Code-tab availability on Linux (officially unsupported per upstream docs), sign-in flow, folder picker, drag-and-drop, and the basic editing surfaces (terminal, file pane). See [`../matrix.md`](../matrix.md) for status.

## T15 — Sign-in completes in the embedded webview

> **Drift in build 1.5354.0** — Sign-in is an in-app `mainView.webContents.loadURL` flow, not an `xdg-open` browser handoff. Claude.ai/login renders inside the embedded BrowserView; the resulting `sessionKey` cookie is then exchanged at `${apiHost}/v1/oauth/${org}/authorize` with redirect URI `https://claude.ai/desktop/callback`. No system browser is involved.

**Severity:** Smoke
**Surface:** Auth / embedded webview
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Launch a fresh app instance (signed-out state).
2. Click **Sign in**. Observe claude.ai/login rendering inside the app.
3. Authenticate. Observe the in-app navigation completing back to the
   workspace.

**Expected:** Sign-in stays inside the embedded webview (`will-navigate`
handler `Ihr` keeps `/login/` paths in-app). After auth the
`sessionKey` cookie is captured and silently exchanged for an OAuth
token via the `desktop/callback` redirect. Account dropdown populates;
no auth banner remains.

**Diagnostics on failure:** DevTools console for the `mainView`
BrowserView, network captures of the `/v1/oauth/{org}/authorize` and
`/v1/oauth/token` calls, launcher log, cookie jar inspection
(`sessionKey` on `.claude.ai`).

**References:** [Code tab auth troubleshooting](https://code.claude.com/docs/en/desktop#403-or-authentication-errors-in-the-code-tab)

**Code anchors:**
- `build-reference/app-extracted/.vite/build/index.js:141996` — desktop
  OAuth redirect URI `https://claude.ai/desktop/callback`
- `build-reference/app-extracted/.vite/build/index.js:142431` — POST to
  `${apiHost}/v1/oauth/${org}/authorize` with `Bearer ${sessionKey}`
- `build-reference/app-extracted/.vite/build/index.js:216565` — `Ihr`
  treats `/login/` paths as in-app (not external)
- `build-reference/app-extracted/.vite/build/index.js:141316` —
  `mainView.webContents.loadURL(...)` drives the embedded sign-in

## T16 — Code tab loads

**Severity:** Smoke
**Surface:** Code tab — top-level UI
**Applies to:** All rows
**Issues:** —

**Steps:**
1. After sign-in, click the **Code** tab at the top center.
2. Wait a few seconds.

**Expected:** Code tab renders the session UI (sidebar, prompt area, environment dropdown). Per upstream docs the Code tab is "not supported" on Linux — the patched build under this project should render the UI normally or surface a clear, actionable message. Not a blank screen, infinite spinner, or `Error 403: Forbidden`.

**Diagnostics on failure:** Screenshot, DevTools console, network captures (auth/feature-flag responses), launcher log, the active patch set in `scripts/patches/`.

**References:** [Use Claude Code Desktop](https://code.claude.com/docs/en/desktop), [Get started with the desktop app](https://code.claude.com/docs/en/desktop-quickstart)

**Code anchors:**
- `build-reference/app-extracted/.vite/build/index.js:525066` —
  `sidebarMode === "code"` rewrites the BrowserView path to `/epitaxy`
- `build-reference/app-extracted/.vite/build/index.js:496066` — Code
  deeplinks (`claude://code?...`) navigate to `/epitaxy?...`
- `build-reference/app-extracted/.vite/build/index.js:105273` — `IHi`
  recognises `/epitaxy` and `/epitaxy/...` as the Code-tab path
- `build-reference/app-extracted/.vite/build/index.js:105346` —
  `sidebarMode` enum contains `"code"`

**Inventory anchor:** `…tablist.tab-by-name.code` (role `tab`, label
`Code`) — confirms the Code tab is reachable from the new-chat tablist
in the captured idle state.

## T17 — Folder picker opens

**Severity:** Smoke
**Surface:** Code tab → Environment selection
**Applies to:** All rows
**Issues:** —
**Runner:** [`tools/test-harness/src/runners/T17_folder_picker.spec.ts`](../../../tools/test-harness/src/runners/T17_folder_picker.spec.ts) — runtime-attach via SIGUSR1 + main-process `dialog.showOpenDialog` mock + `webContents.executeJavaScript` to drive the renderer. Click chain to reach the folder-picker button awaits selector tuning

**Steps:**
1. In the Code tab, click the environment pill → **Local** → **Select folder**.
2. Choose a project directory.

**Expected:** Native file chooser opens. On Wayland sessions the chooser is `xdg-desktop-portal`-backed (verify with `busctl --user tree org.freedesktop.portal.Desktop`). On X11 sessions the GTK/Qt native picker fires. Selected path appears in the env pill.

**Diagnostics on failure:** `systemctl --user status xdg-desktop-portal`, `XDG_SESSION_TYPE`, the portal backend in use (`xdg-desktop-portal-kde`, `xdg-desktop-portal-gnome`, `xdg-desktop-portal-wlr`), launcher log.

**References:** [Local sessions](https://code.claude.com/docs/en/desktop#local-sessions)

**Code anchors:**
- `build-reference/app-extracted/.vite/build/index.js:66403` — IPC
  channel `claude.web_FileSystem_browseFolder` (renderer → main)
- `build-reference/app-extracted/.vite/build/index.js:509188` —
  `browseFolder` impl calls `dialog.showOpenDialog` with
  `properties: ["openDirectory", "createDirectory"]`
- `build-reference/app-extracted/.vite/build/index.js:450534` —
  `grantViaPicker` (Operon host-access folder grant) uses the same
  `["openDirectory"]` shape
- `tools/test-harness/src/lib/claudeai.ts:122` — `installOpenDialogMock`
  intercepts both `(opts)` and `(window, opts)` arities, matching the
  call sites at index.js:509196 and :450534

**Inventory anchor:** `root.main.region.button-by-name.select-folder`
(role `button`, label `Select folder…`) — the persistent button the
T17 runner clicks before the dialog mock fires.

## T18 — Drag-and-drop files into prompt

**Severity:** Critical
**Surface:** Code tab → Prompt area
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Open a Code-tab session.
2. From the system file manager, drag one or more files into the prompt area.
3. Repeat with multiple files at once.

**Expected:** Files attach to the prompt. The renderer resolves dropped
`File` objects to absolute paths via the preload-bridged
`claudeAppSettings.filePickers.getPathForFile` (Electron's
`webUtils.getPathForFile`). Multi-file drops attach each file. Works on
both Wayland and X11.

**Diagnostics on failure:** Screen recording, `wl-paste --list-types` (Wayland) or `xclip -selection clipboard -t TARGETS -o` (X11) during drag, DevTools console, launcher log.

**References:** [Add files and context](https://code.claude.com/docs/en/desktop#add-files-and-context-to-prompts)

**Code anchors:**
- `build-reference/app-extracted/.vite/build/mainView.js:9267` —
  `filePickers.getPathForFile` wraps `webUtils.getPathForFile`
- `build-reference/app-extracted/.vite/build/mainView.js:9552` —
  exposed to the renderer as `window.claudeAppSettings`

## T19 — Integrated terminal

**Severity:** Critical
**Surface:** Code tab → Terminal pane
**Applies to:** All rows
**Issues:** —

**Steps:**
1. In a Code-tab session, press `` Ctrl+` `` (or open via the Views menu).
2. Confirm the terminal opens in the session's working directory.
3. Run `git status`, `npm --version`, `gh auth status`.

**Expected:** Terminal pane opens in the session's working directory, inherits the same `PATH` Claude sees. Standard commands run cleanly. Terminal pane is local-session-only per docs.

**Diagnostics on failure:** Terminal pane content, `echo $PATH` from inside the pane, `pwd`, the shell binary in use, launcher log.

**References:** [Run commands in the terminal](https://code.claude.com/docs/en/desktop#run-commands-in-the-terminal)

**Code anchors:**
- `build-reference/app-extracted/.vite/build/index.js:69135` — IPC
  channel `claude.web_LocalSessions_startShellPty` (also
  `resizeShellPty`, `writeShellPty` at :69184, :69210)
- `build-reference/app-extracted/.vite/build/index.js:486438` —
  `startShellPty` body: spawns `node-pty` in
  `n.worktreePath ?? n.cwd` with `TERM=xterm-256color`
- `build-reference/app-extracted/.vite/build/index.js:486463` —
  `node-pty` dynamic import (optional dep, `package.json` line 100)
- `build-reference/app-extracted/.vite/build/index.js:259306` —
  `shell-path-worker/shellPathWorker.js` resolves the user's interactive
  PATH; `FX()` (line 259311) returns it for the spawned PTY env

## T20 — File pane opens and saves

**Severity:** Critical
**Surface:** Code tab → File pane
**Applies to:** All rows
**Issues:** —

**Steps:**
1. In a Code-tab session, click a file path in chat or diff to open it in the file pane.
2. Make a small edit. Click **Save**.
3. Modify the file externally (e.g. `echo >> file`). Re-edit in the pane. Observe the on-disk-changed warning.

**Expected:** File opens in the editor pane. Edits write back to disk on Save. If the file changed on disk since opening, the pane shows the on-disk-changed warning and offers override or discard. (The conflict check is sha256-based, not mtime-based — `writeSessionFile` reads the current bytes, hashes them, and rejects with `Conflict` if the renderer-supplied `expectedHash` doesn't match.)

**Diagnostics on failure:** `sha256sum <file>` output (and stat mtime for cross-checking), launcher log, DevTools console, screen recording of the warning state.

**References:** [Open and edit files](https://code.claude.com/docs/en/desktop#open-and-edit-files)

**Code anchors:**
- `build-reference/app-extracted/.vite/build/index.js:68922` — IPC
  channel `claude.web_LocalSessions_readSessionFile`
- `build-reference/app-extracted/.vite/build/index.js:69003` — IPC
  channel `claude.web_LocalSessions_writeSessionFile` with
  `expectedHash` argument at position 3
- `build-reference/app-extracted/.vite/build/index.js:492874` —
  `readSessionFile` impl
- `build-reference/app-extracted/.vite/build/index.js:492954` —
  `writeSessionFile` impl: sha256-hashes current on-disk bytes,
  returns `{ status: nW.Conflict, currentHash }` when `expectedHash`
  mismatches
