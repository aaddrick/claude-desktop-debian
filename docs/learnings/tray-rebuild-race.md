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
| `menu_func` | `${tray_var}.setContextMenu(X(` — or, when upstream prebuilds the menu (`M=X(); setContextMenu(M)`), resolved one hop back via `M=X(` |
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

## Startup icon-colour race (leading-edge mutex drop)

A subtler bug lives in the same rebuild function. On a *dark* desktop
(e.g. GNOME `color-scheme=prefer-dark`),
`nativeTheme.shouldUseDarkColors` reads **`false` for the first
~50 ms** of the process, then a burst of `nativeTheme "updated"`
events flips it to `true`. Measured with a standalone Electron probe:

```
[ready+0ms]     shouldUseDarkColors=false   <- tray created -> black icon
[UPDATED-EVENT] shouldUseDarkColors=true    <- ~50-100 ms later
[ready+500ms]   shouldUseDarkColors=true     (stays true)
```

The tray is created with the transient `false` (black). The
correction never lands because the rebuild mutex was a *leading-edge*
throttle (`if(f._running)return;f._running=true;setTimeout(...,1500)`):
the first `"updated"` (false) takes the lock and renders black; the
follow-up `"updated"` (true) events all arrive inside the 1500 ms
window and are **dropped**. No further event fires on its own, so the
icon stays black until a manual theme change forces a new `"updated"`.

The fix makes the mutex *trailing-edge* — a request that arrives while
a rebuild is in flight is remembered and re-run once when the window
clears, so the final value wins:

```js
if (f._running) { f._pending = true; return; }
f._running = true;
setTimeout(() => {
  f._running = false;
  if (f._pending) { f._pending = false; f(); }
}, 1500);
```

The startup-suppression `_trayStartTime > 3e3` guard was removed at
the same time: it gated the very `"updated"` → rebuild call the
correction now depends on. Trade-off: a ~1.5 s black flash at startup
before the trailing re-run lands (vs. permanently black before).
See [#679](https://github.com/aaddrick/claude-desktop-debian/issues/679).

## Pitfalls to watch for

- **No startup window gates the rebuild any more.** An earlier
  `_trayStartTime > 3e3` guard suppressed `tray_func()` for the first
  3 s; it was removed because it also swallowed the startup colour
  correction (see the section above). The trailing-edge mutex bounds
  rebuild frequency instead.
- **macOS path is left untouched.** The condition
  `process.platform !== 'darwin' && …setContextMenu` keeps the
  Electron macOS tray model (right-click pops up a menu via
  `popUpContextMenu(r)` with `r` captured at creation time) intact.
