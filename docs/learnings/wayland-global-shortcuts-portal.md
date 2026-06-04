[< Back to learnings](./)

# Wayland global shortcuts via the XDG GlobalShortcuts portal

Quick Entry's global hotkey (`Ctrl+Alt+Space`) is focus-bound on modern GNOME Wayland; the launcher now routes it through the XDG GlobalShortcuts portal (native Wayland + a merged `--enable-features=…,GlobalShortcutsPortal`), which fixes GNOME ≤ 49 — but GNOME 50 / xdg-desktop-portal ≥ 1.20 is still blocked by an upstream Electron gap ([electron/electron#51875](https://github.com/electron/electron/issues/51875)).

## The problem (#404)

Upstream registers Quick Entry's hotkey with a raw `globalShortcut.register()` (build-reference `index.js:499416`) and has no portal fallback. On X11 that becomes an X11 key grab. The launcher historically defaulted *every* Wayland session to XWayland (`--ozone-platform=x11`) precisely so that grab would keep working.

That stopped working on GNOME. mutter (GNOME ≥ 49) no longer honours XWayland-side global key grabs, so the grab only fires when the Claude window already has focus — the opposite of "open Claude from everywhere." The symptom is intermittent (a brief compositor state can make it appear to work, then it stops), which sent more than one reporter chasing ghosts.

## The launcher change (necessary, not sufficient)

Electron ≥ 35 (we bundle 41) exposes Chromium's `GlobalShortcutsPortal` feature: under the **native Wayland ozone platform** it is *supposed* to route `globalShortcut.register()` through the `org.freedesktop.portal.GlobalShortcuts` D-Bus interface instead of an X11 grab. So the launcher (`scripts/launcher-common.sh`):

1. `detect_display_backend` auto-forces GNOME Wayland to native Wayland (joining Niri, which was already forced for a different reason — no XWayland at all).
2. `build_electron_args` adds `GlobalShortcutsPortal` to the native-Wayland feature set.

KDE/Sway/Hyprland stay on XWayland: their XWayland grabs still work, so there's no reason to take on native-Wayland rendering risk.

This is the correct, required prerequisite, and it is what closes #404 on **GNOME ≤ 49**. It is *not* sufficient on GNOME 50 — see below.

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

**Root cause:** xdg-desktop-portal **1.20+** requires a non-sandboxed ("host") app to declare its identity via `org.freedesktop.host.portal.Registry.Register(app_id, options)` before app-id-gated portals will serve it. Chromium's `GlobalAcceleratorListenerLinux` still relies on the legacy systemd-scope app-id derivation (it creates `app-electron-<pid>.scope` but never calls `Registry.Register`). On portal 1.21 the legacy path no longer yields an app id for host apps, so a manual `CreateSession` returns `org.freedesktop.portal.Error.NotAllowed: An app id is required`.

**Proof the portal itself works** — a ~60-line Python client that performs the missing `Registry.Register` call (reverse-DNS app id backed by a `.desktop` file, launched in a matching `app-<id>.scope` via `systemd-run --user --scope`) drives the whole flow and receives `Activated` from an *unfocused* window:

```
Registry.Register('com.example.GsPortalProof') OK
CreateSession OK
BindShortcuts OK -> id='open-quick-entry' trigger='Press <Control><Alt>space'
*** ACTIVATED *** (press #1)   *** ACTIVATED *** (press #2)
```

Secondary gate: GNOME's backend also rejects app ids that are not reverse-DNS and backed by an installed `.desktop` (`gnome-control-center-global-shortcuts-provider: Discarded shortcut bind request … invalid app_id >gsportalproof<`). Electron's default app id is the executable name (`claude-desktop`), which has no dot and would likely also fail this even once `Registry.Register` is wired up.

Why it works on GNOME ≤ 49: older xdg-desktop-portal derived the app id from the systemd scope automatically and did not require `Registry.Register`. GNOME 50 / portal 1.21 introduced the requirement Chromium hasn't adopted.

Filed upstream: [electron/electron#51875](https://github.com/electron/electron/issues/51875) (fundamentally a Chromium `global_accelerator_listener_linux.cc` gap, surfacing through Electron).

## First-run UX and escape hatch

When the portal path *does* engage (GNOME ≤ 49), GNOME shows a **one-time permission dialog** the first time the shortcut is registered; the user must accept it to bind the shortcut. Expected portal behaviour, not a bug.

`CLAUDE_USE_WAYLAND` is tri-state: `1` forces native Wayland, `0` forces XWayland (skipping auto-detect), unset auto-detects. The `0` value is the escape hatch for a GNOME user who hits a native-Wayland rendering regression and wants the old XWayland behaviour back (losing global-shortcut-from-unfocused in the process — which on GNOME 50 is not yet working anyway).

## wlroots caveat (Niri / Sway / Hyprland)

The portal flag is harmless where the compositor's portal has no GlobalShortcuts backend, but does nothing useful there. wlroots' `xdg-desktop-portal-wlr` ships no GlobalShortcuts implementation, so on Niri `BindShortcuts` fails with `error code 5`. That's the `S14` known-failing detector: the assertion encodes the contract and will start passing if/when the wlroots portal gains the interface — no spec edit needed.

## Tests / anchors

- `tests/launcher-common.bats` — `detect_display_backend` GNOME/`CLAUDE_USE_WAYLAND=0` cases; `build_electron_args` single-merged-flag + portal-present/absent cases.
- `tools/test-harness/src/runners/S12_global_shortcuts_portal_flag.spec.ts` — GNOME-W flag-in-argv detector (passes: the launcher delivers the flag).
- `tools/test-harness/src/runners/S14_quick_entry_from_other_focus_niri.spec.ts` — Niri portal `BindShortcuts` detector (known-failing by design).
- `docs/testing/cases/shortcuts-and-input.md` (S12/S14), `docs/testing/quick-entry-closeout.md` (QE-6).
- Upstream blocker: [electron/electron#51875](https://github.com/electron/electron/issues/51875).
