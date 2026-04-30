# UI — System Tray

Tray icon, menu, and theme variants. See [`../cases/tray-and-window-chrome.md`](../cases/tray-and-window-chrome.md) for related functional tests ([T03](../cases/tray-and-window-chrome.md#t03--tray-icon-present), [S08](../cases/tray-and-window-chrome.md#s08--tray-icon-doesnt-duplicate-after-nativetheme-update)).

## Tray icon

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Tray icon (light theme) | System tray / status area | Black icon (the "Template" variant) renders cleanly on a light tray | — |
| Tray icon (dark theme) | System tray / status area | White icon (the "Template-Dark" variant) renders cleanly on a dark tray | — |
| Theme switch | Trigger system theme change | Icon updates in place — no duplicate icons spawned ([S08](../cases/tray-and-window-chrome.md#s08--tray-icon-doesnt-duplicate-after-nativetheme-update)) | KDE-W ✓ via in-place fast-path |
| Icon resolution / sharpness | Inspect at native scale | Icon is crisp, not pixelated. Check on HiDPI screens | — |
| Position | Tray area | Appears among other SNI/tray icons | KDE Plasma sorts alphabetically by ID; adjusting position requires user config |
| Tooltip on hover | Hover over icon | Shows "Claude" or app name | — |

## Right-click menu

| Element | Position in menu | Expected | Notes |
|---------|------------------|----------|-------|
| Show / Hide window | Top item | Toggles main window visibility | Label may change between "Show" and "Hide" based on state |
| Quick Entry | Mid-menu | Opens Quick Entry popup ([T06](../cases/shortcuts-and-input.md#t06--quick-entry-global-shortcut-unfocused)) | — |
| Open at Login (toggle) | Mid-menu | Reflects current XDG autostart state ([T09](../cases/platform-integration.md#t09--autostart-via-xdg)) | Toggle should write `~/.config/autostart/*.desktop` |
| Settings | Mid-menu | Opens Settings window | — |
| About | Bottom area | Opens About dialog | — |
| Quit | Bottom item | Fully exits the app (no hide-to-tray) | — |
| Menu separators | Between item groups | Render cleanly | — |

## Left-click behavior

| Element | Trigger | Expected | Notes |
|---------|---------|----------|-------|
| Single left-click | Click tray icon once | Toggles main window visibility | KDE-W ✓ |
| Double left-click | Click twice quickly | DE-dependent; should not spawn duplicate windows | — |
| Middle-click | Middle mouse button on tray icon | DE-dependent (no documented behavior); should not crash | — |

## Failure modes to watch for

| Symptom | Likely cause | Diagnose with |
|---------|--------------|---------------|
| Tray icon never appears | No SNI watcher (e.g. GNOME without AppIndicator extension); Electron fallback to legacy XEmbed not registered | `gdbus call ... org.kde.StatusNotifierWatcher` — see [runbook](../runbook.md#tray--dbus-state-kde) |
| Two tray icons after theme switch | Tray rebuild race ([S08](../cases/tray-and-window-chrome.md#s08--tray-icon-doesnt-duplicate-after-nativetheme-update)) | SNI watcher state before/after; [`docs/learnings/tray-rebuild-race.md`](../../learnings/tray-rebuild-race.md) |
| Icon renders as a generic placeholder | Icon path resolution failed; theme mismatch | Check Electron `Tray` constructor args; check `~/.cache/claude-desktop-debian/launcher.log` |
| Menu items don't respond | IPC bridge to tray menu broken; main process busy | Click main window — does the rest of the app respond? `pgrep -af claude`; main process state |
| Tray icon disappears after some time | Tray daemon restarted; Claude didn't re-register | KDE Plasma: restart `plasmashell`; observe whether icon comes back without restarting Claude |
