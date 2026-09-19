[< Back to learnings](./)

# Wayland global shortcuts via the XDG GlobalShortcuts portal

Quick Entry's global hotkey (`Ctrl+Alt+Space`) is focus-bound on modern GNOME Wayland; the native-Wayland path now routes it through the XDG GlobalShortcuts portal (a merged `--enable-features=…,GlobalShortcutsPortal`), opt-in on GNOME via `CLAUDE_USE_WAYLAND=1` — which fixes GNOME ≤ 49 on the bytes it was verified against. GNOME 50 / xdg-desktop-portal ≥ 1.20 was blocked by an upstream Electron gap ([electron/electron#51875](https://github.com/electron/electron/issues/51875)); that closed on 2026-08-23 as fixed in Chromium 152 / Electron 44, which the official build we ship has carried since 2.2553.x (Electron 44.2.0, Chromium 152.0.7977.76). GNOME 50 is therefore *expected* to work now but is unverified by us — #805's Fedora GNOME reporter is the retest (#862).

## The problem (#404)

Upstream registers Quick Entry's hotkey with a raw `globalShortcut.register()` (build-reference `index.js:499416`) and has no portal fallback. On X11 that becomes an X11 key grab. The launcher historically defaulted *every* Wayland session to XWayland (`--ozone-platform=x11`) precisely so that grab would keep working.

That stopped working on GNOME. mutter (GNOME ≥ 49) no longer honours XWayland-side global key grabs, so the grab only fires when the Claude window already has focus — the opposite of "open Claude from everywhere." The symptom is intermittent (a brief compositor state can make it appear to work, then it stops), which sent more than one reporter chasing ghosts.

## The launcher change (necessary, not sufficient)

Electron ≥ 35 (the official build ships 44.2.0 as of 2.2553.1; the 2.x pipeline bundled 41) exposes Chromium's `GlobalShortcutsPortal` feature: under the **native Wayland ozone platform** it is *supposed* to route `globalShortcut.register()` through the `org.freedesktop.portal.GlobalShortcuts` D-Bus interface instead of an X11 grab. So `build_electron_args` adds `GlobalShortcutsPortal` to the native-Wayland feature set.

GNOME Wayland is **not** auto-flipped to native Wayland. `detect_display_backend` still only auto-forces Niri (no XWayland at all). The reason: GNOME Wayland is the default session for a large slice of users, and moving it off mature XWayland is a rendering / IME / HiDPI / fractional-scaling risk — shipped on argv-only verification, and through Electron 43 the portal route was a no-op on GNOME 50 anyway (so those users would have taken the risk for zero benefit; Electron 44 is expected to lift that, unverified). GNOME users opt in with `CLAUDE_USE_WAYLAND=1`, which fully works on **GNOME ≤ 49** after the one-time portal dialog. Auto-selecting native Wayland on GNOME is deferred to a follow-up gated on a real "still renders correctly" check, not just "the flag reached argv."

KDE/Sway/Hyprland likewise stay on XWayland by default (opt in with `=1`).

## Two traps that bite

- **`GlobalShortcutsPortal` is inert under XWayland.** The feature lives in Chromium's ozone/wayland layer. Passing the flag while `--ozone-platform=x11` does nothing. The flag and `--ozone-platform=wayland` are a package deal — that's why the launcher flips the backend, not just appends a flag.

- **Chromium honours only the *last* `--enable-features=` switch.** Two separate `--enable-features=A` `--enable-features=B` on one command line silently drops `A`. When this was diagnosed, `build_electron_args` emitted up to two (`WindowControlsOverlay` for the hidden-titlebar machinery — removed along with that machinery in the v3.0.0 rebase — and `UseOzonePlatform,WaylandWindowDecorations` for native Wayland), so adding a third would have clobbered the others. The function accumulates into one `enable_features` array and emits a single comma-joined `--enable-features=` at the end (today only the native-Wayland set: `UseOzonePlatform,WaylandWindowDecorations,GlobalShortcutsPortal`). The test-harness `argvHasFlag` (`tools/test-harness/src/lib/argv.ts`) already matches a subkey inside a comma-joined value, so `S12` passes against the merged form.

## Why GNOME 50 was broken through Electron 43 — and how it was proven

On Fedora 44 / GNOME 50.2 / xdg-desktop-portal **1.21.2**, `globalShortcut.register()` returns `false` and the portal is **never contacted** (no `CreateSession`, no `BindShortcuts`). The feature flag has zero observable effect:

| ozone backend | `GlobalShortcutsPortal` flag | `register()` | portal `CreateSession` |
|---|---|---|---|
| wayland | enabled | `false` | 0 |
| wayland | default (no flag) | `false` | 0 |
| wayland | disabled | `false` | 0 |
| x11 (XWayland) | enabled | `true` | 0 (X11 grab; mutter ignores it → focus-bound, the #404 symptom) |

Reproduced identically on Electron **40.6.1, 41.5.0, 41.7.1, and 42.3.3** (latest at the time), with the relevant app-id fixes already present (electron#49988 → backported to `41-x-y` via #50051). So the Electron *version* is not the variable.

**Root cause (pinned to source on both sides):** xdg-desktop-portal grew a host-app identity step — non-sandboxed apps must call `org.freedesktop.host.portal.Registry.Register(app_id)` (added in **1.20**, commit `8fd5bdd5ec`), and GlobalShortcuts `CreateSession` now hard-rejects an empty app id (`src/global-shortcuts.c` `handle_create_session()` → `NOT_ALLOWED "An app id is required"`, added in **1.21.0**, commit `38dd2c03f2`). Chromium never makes that call in the normal case: `components/dbus/xdg/portal.cc` `PortalRegistrar::OnServiceChecked()` only calls `Register()` when starting its transient systemd scope *fails* — when the scope starts (`kUnitStarted`, the usual path; the browser creates `app-<id>-<pid>.scope`) it skips `Register()`, assuming the portal derives the app id from the scope. On portal 1.21 that derivation is gone, so the connection has an empty app id and `CreateSession` (issued from `ui/base/accelerators/global_accelerator_listener/global_accelerator_listener_linux.cc`) is rejected. Confirmed on plain Chromium 151 (HEAD) and Chrome 149, not just Electron.

**Proof the portal itself works** — a ~60-line Python client that performs the missing `Registry.Register` call (reverse-DNS app id backed by a `.desktop` file, launched in a matching `app-<id>.scope` via `systemd-run --user --scope`) drives the whole flow and receives `Activated` from an *unfocused* window:

```
Registry.Register('com.example.GsPortalProof') OK
CreateSession OK
BindShortcuts OK -> id='open-quick-entry' trigger='Press <Control><Alt>space'
*** ACTIVATED *** (press #1)   *** ACTIVATED *** (press #2)
```

Secondary gate: GNOME's backend also rejects app ids that are not reverse-DNS and backed by an installed `.desktop` (`gnome-control-center-global-shortcuts-provider: Discarded shortcut bind request … invalid app_id >gsportalproof<`). Electron's default app id is the executable name (`claude-desktop`), which has no dot and would likely also fail this even once `Registry.Register` is wired up.

Why it works on GNOME ≤ 49: older xdg-desktop-portal derived the app id from the systemd scope automatically and did not require `Registry.Register`. GNOME 50 / portal 1.21 introduced the requirement Chromium had not adopted at the time.

Filed upstream: [electron/electron#51875](https://github.com/electron/electron/issues/51875) and the underlying Chromium bug at [crbug 520262204](https://issues.chromium.org/issues/520262204). **Resolved upstream:** Chromium CL 8102824 ("Register app ID with the portal even when a systemd scope started", 2026-07-20) shipped in Chromium 152; the Electron issue closed 2026-08-23 as fixed in Electron 44 with no cherry-pick to 42/43. The official `.deb` moved to Electron 44.2.0 with 2.2553.x, so the gap diagnosed above is history for what we ship, kept as the diagnosis record — fundamentally the `components/dbus/xdg/portal.cc` skip-`Register()`-on-`kUnitStarted` gap, surfacing through Electron.

## First-run UX and escape hatch

When the portal path *does* engage (GNOME ≤ 49), GNOME shows a **one-time permission dialog** the first time the shortcut is registered; the user must accept it to bind the shortcut. Expected portal behaviour, not a bug. A dismissed or denied dialog persists in the portal permission store and later `globalShortcut.register()` calls then fail silently; clearing the stored decision with `flatpak permission-reset <app-id>` (the store is shared with non-Flatpak apps) should re-trigger the dialog on the next launch — untested here.

`CLAUDE_USE_WAYLAND` is tri-state: `1` forces native Wayland, `0` forces XWayland (skipping auto-detect), unset auto-detects. The `0` value is the escape hatch for a GNOME user who hits a native-Wayland rendering regression and wants the old XWayland behaviour back (losing global-shortcut-from-unfocused in the process).

## wlroots caveat (Niri / Sway / Hyprland)

The portal flag is harmless where the compositor's portal has no GlobalShortcuts backend, but does nothing useful there. wlroots' `xdg-desktop-portal-wlr` ships no GlobalShortcuts implementation, so on Niri `BindShortcuts` fails with `error code 5`. That's the `S14` known-failing detector: the assertion encodes the contract and will start passing if/when the wlroots portal gains the interface — no spec edit needed.

## Tests / anchors

- `tests/launcher-common.bats` — `detect_display_backend` GNOME/`CLAUDE_USE_WAYLAND=0` cases; `build_electron_args` single-merged-flag + portal-present/absent cases.
- `tools/test-harness/src/runners/S12_global_shortcuts_portal_flag.spec.ts` — GNOME-W flag-in-argv detector (passes: the launcher delivers the flag).
- `tools/test-harness/src/runners/S14_quick_entry_from_other_focus_niri.spec.ts` — Niri portal `BindShortcuts` detector (known-failing by design).
- `docs/testing/cases/shortcuts-and-input.md` (S12/S14), `docs/testing/quick-entry-closeout.md` (QE-6).
- Upstream blockers (both resolved, fixed in Electron 44 / Chromium 152): [electron/electron#51875](https://github.com/electron/electron/issues/51875), Chromium [crbug 520262204](https://issues.chromium.org/issues/520262204).
