[< Back to learnings](./)

# Wayland global shortcuts via the XDG GlobalShortcuts portal

Quick Entry's global hotkey (`Ctrl+Alt+Space`) is focus-bound on modern GNOME Wayland; the native-Wayland path now routes it through the XDG GlobalShortcuts portal (a merged `--enable-features=…,GlobalShortcutsPortal`), opt-in on GNOME via `CLAUDE_USE_WAYLAND=1` — which fixes GNOME ≤ 49 on the bytes it was verified against. GNOME 50 / xdg-desktop-portal ≥ 1.20 was blocked by an upstream Electron gap ([electron/electron#51875](https://github.com/electron/electron/issues/51875)), fixed in Chromium 152 / Electron 44, which the official build has carried since 2.2553.x. The GNOME 50 retest (2026-09-29, [#805](https://github.com/aaddrick/claude-desktop-debian/issues/805)) showed that fix was necessary but not sufficient: the portal also needs an installed `com.anthropic.Claude.desktop`, which our packages did not ship. The launcher now writes a hidden user-level one on native Wayland ([§ The desktop-id gate](#the-desktop-id-gate-gnome-50-retest-805)), and with it the hotkey works unfocused on GNOME 50.1.

## The problem (#404)

Upstream registers Quick Entry's hotkey with a raw `globalShortcut.register()` (build-reference `index.js:499416`) and has no portal fallback. On X11 that becomes an X11 key grab. The launcher historically defaulted *every* Wayland session to XWayland (`--ozone-platform=x11`) precisely so that grab would keep working.

That stopped working on GNOME. mutter (GNOME ≥ 49) no longer honours XWayland-side global key grabs, so the grab only fires when the Claude window already has focus — the opposite of "open Claude from everywhere." The symptom is intermittent (a brief compositor state can make it appear to work, then it stops), which sent more than one reporter chasing ghosts.

## The launcher change (necessary, not sufficient)

Electron ≥ 35 (the official build ships 44.2.0 as of 2.2553.1; the 2.x pipeline bundled 41) exposes Chromium's `GlobalShortcutsPortal` feature: under the **native Wayland ozone platform** it is *supposed* to route `globalShortcut.register()` through the `org.freedesktop.portal.GlobalShortcuts` D-Bus interface instead of an X11 grab. So `build_electron_args` adds `GlobalShortcutsPortal` to the native-Wayland feature set.

GNOME Wayland is **not** auto-flipped to native Wayland. `detect_display_backend` still only auto-forces Niri (no XWayland at all). The reason: GNOME Wayland is the default session for a large slice of users, and moving it off mature XWayland is a rendering / IME / HiDPI / fractional-scaling risk — shipped on argv-only verification, and through Electron 43 the portal route was a no-op on GNOME 50 anyway (so those users would have taken the risk for zero benefit; Electron 44 is expected to lift that, unverified). GNOME users opt in with `CLAUDE_USE_WAYLAND=1`, which works after the one-time portal dialog: on GNOME ≤ 49 as-is, on GNOME 50 with the app-id entry the launcher writes (#805). Auto-selecting native Wayland on GNOME is deferred to a follow-up gated on a real "still renders correctly" check, not just "the flag reached argv."

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

Secondary gate: GNOME's backend also rejects app ids that are not reverse-DNS and backed by an installed `.desktop` (`gnome-control-center-global-shortcuts-provider: Discarded shortcut bind request … invalid app_id >gsportalproof<`). The id Chromium registers is not the executable name but the asar `desktopName` minus `.desktop` (`com.anthropic.Claude`), which is reverse-DNS; the `.desktop` half is what bit on the retest (next section).

Why it works on GNOME ≤ 49: older xdg-desktop-portal derived the app id from the systemd scope automatically and did not require `Registry.Register`. GNOME 50 / portal 1.21 introduced the requirement Chromium had not adopted at the time.

Filed upstream: [electron/electron#51875](https://github.com/electron/electron/issues/51875) and the underlying Chromium bug at [crbug 520262204](https://issues.chromium.org/issues/520262204). **Resolved upstream:** Chromium CL 8102824 ("Register app ID with the portal even when a systemd scope started", 2026-07-20) shipped in Chromium 152; the Electron issue closed 2026-08-23 as fixed in Electron 44 with no cherry-pick to 42/43. The official `.deb` moved to Electron 44.2.0 with 2.2553.x, so the gap diagnosed above is history for what we ship, kept as the diagnosis record — fundamentally the `components/dbus/xdg/portal.cc` skip-`Register()`-on-`kUnitStarted` gap, surfacing through Electron.

## The desktop-id gate (GNOME 50 retest, #805)

Retested 2026-09-29 on Ubuntu 26.04.1, GNOME Shell 50.1 (Wayland), xdg-desktop-portal 1.21.1, xdg-desktop-portal-gnome 50.0, `claude-desktop-unofficial` 2.9939.4-3.3.0 (Electron 44.4.3, Chromium 152.0.7977.130), with `dbus-monitor` on the portal interfaces. Electron 44 does now call `Registry.Register` — and the portal refuses it:

```
Registry.Register('com.anthropic.Claude')
  -> org.freedesktop.portal.Error.Failed: Could not register app ID: App info not found for 'com.anthropic.Claude'
GlobalShortcuts.CreateSession
  -> org.freedesktop.portal.Error.NotAllowed: An app id is required
BindShortcuts: never called.  Activated: 0.
```

xdg-desktop-portal ≥ 1.20 resolves the id through `GDesktopAppInfo`, so it accepts an id only when `<id>.desktop` is installed in the data dirs the portal sees. `gdbus call … org.freedesktop.host.portal.Registry.Register <id> '{}'` reproduces that without the app: `org.gnome.Nautilus` and `claude-desktop-unofficial` return `()`, `com.anthropic.Claude` returns the error above. The official `.deb` ships `/usr/share/applications/com.anthropic.Claude.desktop`; our packages install `claude-desktop-unofficial.desktop`, so the id Chromium registers has no entry.

With a hidden `~/.local/share/applications/com.anthropic.Claude.desktop` in place, the same run goes through: `Register` OK, `CreateSession` OK, the GNOME permission dialog appears, `BindShortcuts` OK, `Activated` fires with another app focused, and `org.gnome.settings-daemon.global-shortcuts` records `[com.anthropic.Claude] '<Control><Alt>space'`. That test entry was a copy of the installed one (`StartupWMClass` included) plus `NoDisplay=true`, and no duplicate dash icon appeared. The entry the launcher ships drops `StartupWMClass`, so GNOME's `StartupWMClass` lookup can only resolve the window to the visible entry; that exact file, written by `ensure_portal_app_id_entry` itself, gave the same result (`BindShortcuts` OK, `Activated` with another app focused, still one dash icon). The default XWayland launch on the same host stayed focus-bound — `--ozone-platform=x11`, no `CreateSession`, the #404 X11-grab symptom — so `CLAUDE_USE_WAYLAND=1` remains the opt-in that fixes it.

Why a launcher-written user file and not a packaged one: the official package owns `/usr/share/applications/com.anthropic.Claude.desktop` and we install side-by-side with it ([D-002](../decisions.md)), so shipping that path is a dpkg/rpm file conflict. The id itself cannot move without an asar patch — Electron's init sets `CHROME_DESKTOP` from `desktopName`, overriding any launcher env. So `ensure_portal_app_id_entry` (`scripts/launcher-common.sh`) runs after `detect_display_backend` in every launcher and:

- writes the entry (`NoDisplay=true`, `Exec=… %u`, `MimeType=x-scheme-handler/claude;`, no `StartupWMClass`, marker `X-Claude-Desktop-Debian-Portal-Alias=true`) only on native Wayland and only when no `com.anthropic.Claude.desktop` exists in `XDG_DATA_DIRS`. Once written, the entry is the `claude://` handler: the app calls `setAsDefaultProtocolClient('claude')` on every startup, which sets `x-scheme-handler/claude=com.anthropic.Claude.desktop` in `~/.config/mimeapps.list`. Without `%u`, GIO launches (the browser's sign-in callback) dropped the URL and sign-in never finished ([#916](https://github.com/aaddrick/claude-desktop-debian/issues/916)). `xdg-mime query default` still names the packaged entry, which hides this; ask `gio mime x-scheme-handler/claude`. Because that `mimeapps.list` line outlives the native Wayland launch, an existing marked entry is kept current on any backend;
- deletes its own marked entry as soon as a system one appears, so it stops shadowing the official menu entry (a user-data-dir file wins over a system one with the same id);
- leaves any other entry in place and logs `Left portal app-id entry … in place`, with one exception. The official app writes its own copy of the entry to the same path (`X-Claude-Generated=true`, `TryExec` = the official `Exec`), but only while the official system entry exists. That copy outlives the official package, and once its `TryExec` stops resolving, GLib rejects it and the portal again answers `App info not found`. So an `X-Claude-Generated=true` entry whose `TryExec` does not resolve is treated as dead and replaced (`_portal_entry_is_stale_generated`; found by @sabiut in review on the real portal). The two writers never fight: the app skips a user file without its own marker, and it only writes while a system entry exists, which is exactly when the launcher hands the path back.

The one gap: right after the official package is installed, our entry still shadows its menu entry until our launcher runs once more. Nix is unaffected — the derivation ships the official tree, `com.anthropic.Claude.desktop` included.

## First-run UX and escape hatch

When the portal path engages, GNOME shows a **one-time permission dialog** the first time the shortcut is registered; the user must accept it to bind the shortcut. Expected portal behaviour, not a bug. A dismissed or denied dialog persists in the portal permission store and later `globalShortcut.register()` calls then fail silently; clearing the stored decision with `flatpak permission-reset <app-id>` (the store is shared with non-Flatpak apps) should re-trigger the dialog on the next launch — untested here.

`CLAUDE_USE_WAYLAND` is tri-state: `1` forces native Wayland, `0` forces XWayland (skipping auto-detect), unset auto-detects. The `0` value is the escape hatch for a GNOME user who hits a native-Wayland rendering regression and wants the old XWayland behaviour back (losing global-shortcut-from-unfocused in the process).

## wlroots caveat (Niri / Sway / Hyprland)

The portal flag is harmless where the compositor's portal has no GlobalShortcuts backend, but does nothing useful there. wlroots' `xdg-desktop-portal-wlr` ships no GlobalShortcuts implementation, so on Niri `BindShortcuts` fails with `error code 5`. That's the `S14` known-failing detector: the assertion encodes the contract and will start passing if/when the wlroots portal gains the interface — no spec edit needed.

## Tests / anchors

- `tests/launcher-common.bats` — `detect_display_backend` GNOME/`CLAUDE_USE_WAYLAND=0` cases; `build_electron_args` single-merged-flag + portal-present/absent cases.
- `tests/launcher-common.bats` — `ensure_portal_app_id_entry` cases (write on native Wayland, no-op on XWayland/X11/empty launcher, system entry skips and removes ours, user-authored entry untouched, `%u` and `MimeType` present, a pre-#916 entry healed on every backend); `tests/launcher-prelaunch-calls.bats` pins the call in all three launchers, after `detect_display_backend`.
- `tools/test-harness/src/runners/S12_global_shortcuts_portal_flag.spec.ts` — GNOME-W flag-in-argv detector (passes: the launcher delivers the flag).
- `tools/test-harness/src/runners/S14_quick_entry_from_other_focus_niri.spec.ts` — Niri portal `BindShortcuts` detector (known-failing by design).
- `docs/testing/cases/shortcuts-and-input.md` (S12/S14), `docs/testing/quick-entry-closeout.md` (QE-6).
- Upstream blockers (both resolved, fixed in Electron 44 / Chromium 152): [electron/electron#51875](https://github.com/electron/electron/issues/51875), Chromium [crbug 520262204](https://issues.chromium.org/issues/520262204).
