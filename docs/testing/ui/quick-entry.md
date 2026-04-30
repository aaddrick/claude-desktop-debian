# UI — Quick Entry Popup

The Quick Entry popup is the global-shortcut-triggered prompt overlay. Related functional tests: [T06](../cases/shortcuts-and-input.md#t06--quick-entry-global-shortcut-unfocused), [S09](../cases/shortcuts-and-input.md#s09--quick-window-patch-runs-only-on-kde-post-406-gate), [S10](../cases/shortcuts-and-input.md#s10--quick-entry-popup-is-transparent-no-opaque-square-frame).

## Window appearance

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Window frame | None (frameless popup) | No OS-titlebar; no close/min/max buttons | The window is intentionally borderless |
| Background | Behind prompt UI | Transparent (no opaque square frame visible) on KDE Plasma Wayland ([S10](../cases/shortcuts-and-input.md#s10--quick-entry-popup-is-transparent-no-opaque-square-frame)) | KDE-W: pending; bug if opaque |
| Rounded corners | Outer edge of UI | Visible | Compositor must support corner rounding via shaders / clip mask |
| Drop shadow | Around popup | Renders if compositor supports it | wlroots compositors without server-side decorations may not show shadows |
| Position | Center of focused screen, or last position | Appears in expected location relative to current cursor / focused output | DE-dependent |
| Always-on-top | Window manager hint | Stays above other windows | Confirms `setAlwaysOnTop(true)` on the BrowserWindow |

## Input area

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Text input field | Center of popup | Receives focus immediately on open; cursor blinks | — |
| Placeholder text | Empty input state | Shows guidance like "Ask Claude anything..." | — |
| Multi-line autosize | Type a long prompt | Input grows downward as text wraps; popup grows with it | — |
| `Enter` to submit | Press Enter | Sends prompt, closes popup | — |
| `Shift+Enter` for newline | Press Shift+Enter | Inserts newline, doesn't submit | — |
| `Esc` to dismiss | Press Esc | Closes popup without submitting | — |
| Click outside | Click outside the popup window | Closes popup without submitting | — |
| Paste behavior | Paste rich text | Text-only paste; no HTML residue | — |
| IME / dead-key composition | Type composed characters | Composition UI renders correctly above the input | Fcitx5/IBus integration is fragile under Electron |

## Submit feedback

| Element | Trigger | Expected | Notes |
|---------|---------|----------|-------|
| Submit transition | Press Enter | Popup closes; main window opens (or focuses) and shows the new session in flight | — |
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
