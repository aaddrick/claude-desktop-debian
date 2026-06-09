[< Back to learnings](./)

# Wayland global shortcuts via the XDG GlobalShortcuts portal

Quick Entry's global hotkey (`Ctrl+Alt+Space`) is focus-bound on modern GNOME Wayland; the native-Wayland path now routes it through the XDG GlobalShortcuts portal (a merged `--enable-features=…,GlobalShortcutsPortal`), opt-in on GNOME via `CLAUDE_USE_WAYLAND=1` — which fixes GNOME ≤ 49, but GNOME 50 / xdg-desktop-portal ≥ 1.20 is still blocked by an upstream Electron gap ([electron/electron#51875](https://github.com/electron/electron/issues/51875)).

## The problem (#404)

Upstream registers Quick Entry's hotkey with a raw `globalShortcut.register()` (build-reference `index.js:499416`) and has no portal fallback. On X11 that becomes an X11 key grab. The launcher historically defaulted *every* Wayland session to XWayland (`--ozone-platform=x11`) precisely so that grab would keep working.

That stopped working on GNOME. mutter (GNOME ≥ 49) no longer honours XWayland-side global key grabs, so the grab only fires when the Claude window already has focus — the opposite of "open Claude from everywhere." The symptom is intermittent (a brief compositor state can make it appear to work, then it stops), which sent more than one reporter chasing ghosts.

## The launcher change (necessary, not sufficient)

Electron ≥ 35 (we bundle 41) exposes Chromium's `GlobalShortcutsPortal` feature: under the **native Wayland ozone platform** it is *supposed* to route `globalShortcut.register()` through the `org.freedesktop.portal.GlobalShortcuts` D-Bus interface instead of an X11 grab. So `build_electron_args` adds `GlobalShortcutsPortal` to the native-Wayland feature set.

GNOME Wayland is **not** auto-flipped to native Wayland. `detect_display_backend` still only auto-forces Niri (no XWayland at all). The reason: GNOME Wayland is the default session for a large slice of users, and moving it off mature XWayland is a rendering / IME / HiDPI / fractional-scaling risk — shipped on argv-only verification, and on GNOME 50 the portal route is a no-op anyway (so those users would take the risk for zero benefit). GNOME users opt in with `CLAUDE_USE_WAYLAND=1`, which fully works on **GNOME ≤ 49** after the one-time portal dialog. Auto-selecting native Wayland on GNOME is deferred to a follow-up gated on a real "still renders correctly" check, not just "the flag reached argv."

KDE/Sway/Hyprland likewise stay on XWayland by default (opt in with `=1`).

## Two traps that bite

- **`GlobalShortcutsPortal` is inert under XWayland.** The feature lives in Chromium's ozone/wayland layer. Passing the flag while `--ozone-platform=x11` does nothing. The flag and `--ozone-platform=wayland` are a package deal — that's why the launcher flips the backend, not just appends a flag.

- **Chromium honours only the *last* `--enable-features=` switch.** Two separate `--enable-features=A` `--enable-features=B` on one command line silently drops `A`. `build_electron_args` previously emitted up to two (`WindowControlsOverlay` for hidden titlebars; `UseOzonePlatform,WaylandWindowDecorations` for native Wayland), so adding a third would have clobbered the others. The function now accumulates into one `enable_features` array and emits a single comma-joined `--enable-features=` at the end. The test-harness `argvHasFlag` (`tools/test-harness/src/lib/argv.ts`) already matches a subkey inside a comma-joined value, so `S12` passes against the merged form.

## Why GNOME 50 is still broken — and how it was proven

On Fedora 44 / GNOME 50.2 / xdg-desktop-portal **1.21.2**, `globalShortcut.register()` returns `false` and the portal is **never contacted** (no `CreateSession`, no `BindShortcuts`). The feature flag has zero observable effect:

| ozone backend | `GlobalShortcutsPortal` flag | `register()` | portal `CreateSession` |
|---|---|---|---|
| wayland | enabled | `false` | 0 |
| wayland | default (no flag) | `false` | 0 |
| wayland | disabled | `false` | 0 |
| x11 (XWayland) | enabled | `true` | 0 (X11 grab; mutter ignores it → focus-bound, the #404 symptom) |

Reproduced identically on Electron **40.6.1, 41.5.0, 41.7.1, and 42.3.3** (latest), with the relevant app-id fixes already present (electron#49988 → backported to `41-x-y` via #50051). So the Electron *version* is not the variable.

**Root cause (pinned to source on both sides):** xdg-desktop-portal grew a host-app identity step — non-sandboxed apps must call `org.freedesktop.host.portal.Registry.Register(app_id)` (added in **1.20**, commit `8fd5bdd5ec`), and GlobalShortcuts `CreateSession` now hard-rejects an empty app id (`src/global-shortcuts.c` `handle_create_session()` → `NOT_ALLOWED "An app id is required"`, added in **1.21.0**, commit `38dd2c03f2`). Chromium never makes that call in the normal case: `components/dbus/xdg/portal.cc` `PortalRegistrar::OnServiceChecked()` only calls `Register()` when starting its transient systemd scope *fails* — when the scope starts (`kUnitStarted`, the usual path; the browser creates `app-<id>-<pid>.scope`) it skips `Register()`, assuming the portal derives the app id from the scope. On portal 1.21 that derivation is gone, so the connection has an empty app id and `CreateSession` (issued from `ui/base/accelerators/global_accelerator_listener/global_accelerator_listener_linux.cc`) is rejected. Confirmed on plain Chromium 151 (HEAD) and Chrome 149, not just Electron.

**Proof the portal itself works** — a ~60-line Python client that performs the missing `Registry.Register` call (reverse-DNS app id backed by a `.desktop` file, launched in a matching `app-<id>.scope` via `systemd-run --user --scope`) drives the whole flow and receives `Activated` from an *unfocused* window:

```
Registry.Register('com.example.GsPortalProof') OK
CreateSession OK
BindShortcuts OK -> id='open-quick-entry' trigger='Press <Control><Alt>space'
*** ACTIVATED *** (press #1)   *** ACTIVATED *** (press #2)
```

Secondary gate: GNOME's backend also rejects app ids that are not reverse-DNS and backed by an installed `.desktop` (`gnome-control-center-global-shortcuts-provider: Discarded shortcut bind request … invalid app_id >gsportalproof<`). Electron's default app id is the executable name (`claude-desktop`), which has no dot and would likely also fail this even once `Registry.Register` is wired up.

Why it works on GNOME ≤ 49: older xdg-desktop-portal derived the app id from the systemd scope automatically and did not require `Registry.Register`. GNOME 50 / portal 1.21 introduced the requirement Chromium hasn't adopted.

Filed upstream: [electron/electron#51875](https://github.com/electron/electron/issues/51875) (accepted, milestone `42-x-y`) and the underlying Chromium bug at [crbug 520262204](https://issues.chromium.org/issues/520262204) — fundamentally the `components/dbus/xdg/portal.cc` skip-`Register()`-on-`kUnitStarted` gap, surfacing through Electron.

## First-run UX and escape hatch

When the portal path *does* engage (GNOME ≤ 49), GNOME shows a **one-time permission dialog** the first time the shortcut is registered; the user must accept it to bind the shortcut. Expected portal behaviour, not a bug. A dismissed or denied dialog persists in the portal permission store and later `globalShortcut.register()` calls then fail silently; clearing the stored decision with `flatpak permission-reset <app-id>` (the store is shared with non-Flatpak apps) should re-trigger the dialog on the next launch — untested here.

`CLAUDE_USE_WAYLAND` is tri-state: `1` forces native Wayland, `0` forces XWayland (skipping auto-detect), unset auto-detects. The `0` value is the escape hatch for a GNOME user who hits a native-Wayland rendering regression and wants the old XWayland behaviour back (losing global-shortcut-from-unfocused in the process — which on GNOME 50 is not yet working anyway).

## wlroots caveat (Niri / Sway / Hyprland)

The portal flag is harmless where the compositor's portal has no GlobalShortcuts backend, but does nothing useful there. wlroots' `xdg-desktop-portal-wlr` ships no GlobalShortcuts implementation, so on Niri `BindShortcuts` fails with `error code 5`. That's the `S14` known-failing detector: the assertion encodes the contract and will start passing if/when the wlroots portal gains the interface — no spec edit needed.

## Tests / anchors

- `tests/launcher-common.bats` — `detect_display_backend` GNOME/`CLAUDE_USE_WAYLAND=0` cases; `build_electron_args` single-merged-flag + portal-present/absent cases.
- `tools/test-harness/src/runners/S12_global_shortcuts_portal_flag.spec.ts` — GNOME-W flag-in-argv detector (passes: the launcher delivers the flag).
- `tools/test-harness/src/runners/S14_quick_entry_from_other_focus_niri.spec.ts` — Niri portal `BindShortcuts` detector (known-failing by design).
- `docs/testing/cases/shortcuts-and-input.md` (S12/S14), `docs/testing/quick-entry-closeout.md` (QE-6).
- Upstream blockers: [electron/electron#51875](https://github.com/electron/electron/issues/51875), Chromium [crbug 520262204](https://issues.chromium.org/issues/520262204).
