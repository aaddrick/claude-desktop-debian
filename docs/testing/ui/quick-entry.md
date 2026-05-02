# UI — Quick Entry Popup

The Quick Entry popup is the global-shortcut-triggered prompt overlay. Related functional tests: [T06](../cases/shortcuts-and-input.md#t06--quick-entry-global-shortcut-unfocused), [S09](../cases/shortcuts-and-input.md#s09--quick-window-patch-runs-only-on-kde-post-406-gate), [S10](../cases/shortcuts-and-input.md#s10--quick-entry-popup-is-transparent-no-opaque-square-frame), [S29](../cases/shortcuts-and-input.md#s29--quick-entry-popup-is-created-lazily-on-first-shortcut-press-closed-to-tray-sanity), [S33](../cases/shortcuts-and-input.md#s33--quick-entry-transparent-rendering-tracked-against-bundled-electron-version), [S35](../cases/shortcuts-and-input.md#s35--quick-entry-popup-position-is-persisted-across-invocations-and-across-app-restarts), [S36](../cases/shortcuts-and-input.md#s36--quick-entry-popup-falls-back-to-primary-display-when-saved-monitor-is-gone), [S37](../cases/shortcuts-and-input.md#s37--quick-entry-popup-remains-functional-after-main-window-destroy).

## Window appearance

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Window frame | None (frameless popup) | No OS-titlebar; no close/min/max buttons | Upstream sets `frame: false` on the BrowserWindow (`index.js:515381`) |
| Background | Behind prompt UI | Transparent (no opaque square frame visible) on KDE Plasma Wayland ([S10](../cases/shortcuts-and-input.md#s10--quick-entry-popup-is-transparent-no-opaque-square-frame)) | Upstream already sets both `transparent: true` and `backgroundColor: "#00000000"` (`index.js:515380, 515383`). #370 regression is below the option-passing layer (Electron 41.0.4 CSD rework). KDE-W: pending; bug if opaque |
| Rounded corners | Outer edge of UI | Visible | Compositor must support corner rounding via shaders / clip mask |
| Drop shadow | Around popup | macOS-only at the Electron level; on Linux/Windows depends entirely on compositor | Upstream sets `hasShadow: Zr` where `Zr === process.platform === "darwin"` (`index.js:515384`). Linux is expected to render via compositor shadow support; wlroots without server-side decorations will not show one |
| Position | Last-saved position, keyed on monitor; falls back to primary display if monitor is gone | Popup remembers its position across invocations and across app restarts ([S35](../cases/shortcuts-and-input.md#s35--quick-entry-popup-position-is-persisted-across-invocations-and-across-app-restarts), [S36](../cases/shortcuts-and-input.md#s36--quick-entry-popup-falls-back-to-primary-display-when-saved-monitor-is-gone)) | Upstream uses `an.get("quickWindowPosition")` (`index.js:515491-515526`) keyed on monitor label + resolution. Falls back to `cHn()` (`:515502`) when the saved monitor is gone. **Upstream does NOT place on cursor display or focused-window display** — it's last-position or primary, nothing else |
| Always-on-top | Window manager hint | Stays above other windows | Upstream sets `alwaysOnTop: true` with level `"pop-up-menu"` (`index.js:515399`). On macOS this is per-app; on Linux compositors the level hint is interpreted variably |
| Lifecycle | Lazy-created on first shortcut press | First shortcut press constructs the BrowserWindow; subsequent presses reuse it ([S29](../cases/shortcuts-and-input.md#s29--quick-entry-popup-is-created-lazily-on-first-shortcut-press-closed-to-tray-sanity)) | Upstream `if (!Ko \|\| ...) Ko = new BrowserWindow(...)` near `index.js:515375`. Means popup works in tray-only state with no main window mapped |
| Persistence after main window destroy | Popup survives `mainWindow.destroy()` | Popup remains functional; submit guards skip show/focus when `ut` is destroyed ([S37](../cases/shortcuts-and-input.md#s37--quick-entry-popup-remains-functional-after-main-window-destroy)) | Upstream `!ut \|\| ut.isDestroyed()` guard at `index.js:515595`. Likely unreachable on this project due to hide-to-tray override of X button |

## Input area

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Text input field | Center of popup | Receives focus immediately on open; cursor blinks | — |
| Placeholder text | Empty input state | Shows guidance like "Ask Claude anything..." | — |
| Multi-line autosize | Type a long prompt | Input grows downward as text wraps; popup grows with it | — |
| `Enter` to submit | Press Enter | Sends prompt, closes popup. Prompt must be > 2 chars trimmed (`index.js:515530, 515533`); 1-2 char prompts are silently dropped | Renderer-side keymap; reaches main process via IPC `requestDismissWithPayload()` (`:515409`) |
| `Shift+Enter` for newline | Press Shift+Enter | Inserts newline, doesn't submit | Renderer-side |
| `Esc` to dismiss | Press Esc | Closes popup without submitting | Renderer-side; reaches main process via IPC `requestDismiss()` (`:515409`) |
| Click outside | Click outside the popup window | Closes popup without submitting | Wired in **main process** via the popup's `blur` handler (`Ko.on("blur", () => g3A(null))` at `index.js:515465`) |
| Paste behavior | Paste rich text | Text-only paste; no HTML residue | — |
| IME / dead-key composition | Type composed characters | Composition UI renders correctly above the input | Fcitx5/IBus integration is fragile under Electron |

## Submit feedback

| Element | Trigger | Expected | Notes |
|---------|---------|----------|-------|
| Submit transition | Press Enter | Popup closes; main window navigates to a **new** chat session ([S31](../cases/shortcuts-and-input.md#s31--quick-entry-submit-makes-the-new-chat-reachable-from-any-main-window-state)). Quick Entry never appends to existing chats — `ynt(e)` at `index.js:515546` always creates new | Upstream calls `mainWin.show()` + `mainWin.focus()` only — no `restore()`, no workspace migration. Behavior on minimized / hidden / cross-workspace main is compositor-dependent |
| Loading indicator | While prompt is in flight | Brief spinner or fade-out — popup should not appear frozen | — |
| Error state | Submit when offline / API error | Inline error message; popup stays open so user can retry | — |

## Failure modes to watch for

| Symptom | Likely cause | Diagnose with |
|---------|--------------|---------------|
| Popup doesn't appear when shortcut pressed | Global shortcut not registered ([T06](../cases/shortcuts-and-input.md#t06--quick-entry-global-shortcut-unfocused), [S11](../cases/shortcuts-and-input.md#s11--quick-entry-shortcut-fires-from-any-focus-on-wayland-mutter-xwayland-key-grab), [S14](../cases/shortcuts-and-input.md#s14--global-shortcuts-via-xdg-portal-work-on-niri)) | Launcher log; portal `BindShortcuts` outcome |
| Opaque square frame visible behind UI | Transparent background not respected ([S10](../cases/shortcuts-and-input.md#s10--quick-entry-popup-is-transparent-no-opaque-square-frame)) | KDE compositor settings; BrowserWindow `transparent: true` arg |
| Popup appears but input doesn't auto-focus | Focus stealing prevention by compositor; race in BrowserWindow `show()` + `focus()` | Wayland focus-request semantics; mutter is most strict |
| IME composition cursor renders in wrong place | Electron IME integration bug | Try with simpler GTK app to isolate; report upstream Electron issue if reproducible |
| Popup persists after submit | Close-on-submit IPC missed | Launcher log; DevTools console (if reachable on the popup window) |
| Popup appears on wrong monitor / wrong workspace | Compositor places frameless windows differently | Test with `xdotool getactivewindow` (X11) before/after |
