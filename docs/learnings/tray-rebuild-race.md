# Tray icon rebuild race on OS theme change

Why destroy + delay + recreate isn't enough on KDE, and what the
in-place fast-path does differently.

## The bug

Claude Desktop's tray icon follows the OS theme via
`nativeTheme.on('updated', ...)` — every theme change re-runs the
tray rebuild function so the icon PNG can be switched. That rebuild
calls `tray.destroy()`, nulls the reference, sleeps 250 ms (added
earlier to bound DBus-teardown timing), then instantiates a fresh
`new Tray(image)`.

Destroying the `Tray` deregisters the app's StatusNotifierItem from
the session bus (`org.kde.StatusNotifierWatcher.UnregisterItem`);
the new `Tray()` call registers a brand-new one. On KDE Plasma's
`systemtray` widget the window between "unregister signal emitted"
and "plasmoid observer reacts" can exceed 250 ms, during which both
the old SNI name and the new one coexist in the widget's internal
list — the user sees **two Claude icons side by side** until the
next session start.

250 ms is genuinely enough on some setups (the delay was landed
because a larger gap was introducing a visible icon flash); it
isn't enough on others. Timing depends on the compositor version,
portal implementation, and presumably hardware speed, so widening
the delay is just moving the goalposts — the race is structural.

## Triggers

Any system-wide appearance change that makes Chromium emit
`nativeTheme::updated` trips the same code path. Verified triggers
in KDE System Settings:

- **Appearance → Colors** (application colour scheme dropdown)
- **Appearance → Plasma Style** (panel/widget theme)
- **Appearance → Global Theme** (look-and-feel package)

All three route through `org.freedesktop.appearance` /
`KGlobalSettings` signals that Chromium observes, so they all
re-enter the tray rebuild function and all reproduce the duplicate
icon.

## The fix

`patch_tray_inplace_update` (in `scripts/patches/tray.sh`) injects
a fast-path at the top of the rebuild function:

```js
if (Nh && e !== false) {
  Nh.setImage(pA.nativeImage.createFromPath(t));
  process.platform !== 'darwin' && Nh.setContextMenu(wAt());
  return;
}
```

When the tray already exists and isn't being disabled, the patch
updates the icon and the context menu on the **existing**
`StatusNotifierItem` — `setImage` and `setContextMenu` don't
re-register the SNI on DBus, they emit `NewIcon` / `LayoutUpdated`
signals, which the host consumes in-place. No race.

The original destroy + recreate slow-path is kept intact for two
cases that legitimately require it:

- **Initial creation** — `Nh` is `undefined`, so the fast-path
  guard short-circuits and the slow path runs.
- **Disabling the tray** — `e === false` (user turned the tray off
  via `menuBarEnabled` setting) means the tray should be destroyed
  outright, not re-imaged.

## Resilience to minifier churn

Variable names (`Nh`, `pA`, `wAt`, `t`, `e`) drift between upstream
releases. All five are extracted dynamically in `tray.sh`:

| Local | Extraction anchor |
|--|--|
| `tray_func` | `on("menuBarEnabled",()=>{ … })` |
| `tray_var` | `});let X=null;(async )?function ${tray_func}` |
| `electron_var` | already extracted earlier in `_common.sh` |
| `menu_func` | `${tray_var}.setContextMenu(X(`  |
| `path_var` | `${tray_var}=new ${electron_var}.Tray(${electron_var}.nativeImage.createFromPath(X))` |
| `enabled_var` | `const X = fn("menuBarEnabled")` |

Idempotency guard keys on the distinctive
`${tray_var}.setImage(${electron_var}.nativeImage.createFromPath(${path_var}))`
sequence using post-rename extracted names, so re-running the patch
on an already-patched asar is a no-op even after the minifier
churns.

## Verification

Reproduced on Fedora Linux 43 (KDE Plasma Desktop Edition) with
Plasma 6.6.4, `xdg-desktop-portal-kde` 6.6.4, Wayland session,
kernel 6.19.12.

Steps on pristine `main` (before this patch):

```bash
git clone https://github.com/aaddrick/claude-desktop-debian.git
cd claude-desktop-debian
./build.sh --build appimage --clean no
./claude-desktop-*-amd64.AppImage
# Then in KDE Settings → Appearance, flip any of Colors /
# Plasma Style / Global Theme. Two tray icons appear.
```

After the patch: one SNI stays registered for the app's lifetime,
icon updates in place on every theme change.

## Pitfalls to watch for

- **Fast-path runs inside the 3 s startup window too.** The
  existing `_trayStartTime > 3e3` guard only gates the
  `nativeTheme.on('updated')` → `tray_func()` call; once
  `tray_func()` is running for any reason, our fast-path executes.
  Fine — it's cheaper than the slow path even at startup.
- **macOS path is left untouched.** The condition
  `process.platform !== 'darwin' && …setContextMenu` keeps the
  Electron macOS tray model (right-click pops up a menu via
  `popUpContextMenu(r)` with `r` captured at creation time) intact.
