[< Back to README](../README.md)

# Configuration

The launcher reads a small set of opt-in `CLAUDE_*` environment variables; everything else — window frame, menu bar, close-to-tray, hardware acceleration — is a native setting in the official app.

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_USE_WAYLAND` | unset (auto) | Force the display backend on Wayland: `1` = native Wayland, `0` = XWayland. Unset auto-detects per compositor (only Niri defaults to native Wayland). See [Wayland Support](#wayland-support). |
| `CLAUDE_DISABLE_GPU` | unset (auto) | `1` = disable hardware acceleration (`--disable-gpu --disable-software-rasterizer`). `0` = suppress the sticky auto-recovery after a GPU-process crash. Unset = auto-apply the flags when the previous launch died with the GPU FATAL signature. See [GPU](#gpu-claude_disable_gpu). |
| `CLAUDE_PASSWORD_STORE` | unset | Explicit escape hatch: when set, the value is passed verbatim as Chromium's `--password-store=`. When unset, the official build's `os_crypt` autodetection owns the decision. See [Password store](#password-store-claude_password_store). |
| `CLAUDE_GTK_IM_MODULE` | unset | Propagated to `GTK_IM_MODULE` for Electron at startup; opt-in override for broken IBus/GTK input-method integration. See [Input method](#input-method-claude_gtk_im_module). |
| `CLAUDE_TRAY_USE_DARK_ICON` | unset (auto on Cinnamon) | `1` = use upstream's light `TrayIconLinux-Dark.png` (for dark panels); `0` = force the dark `TrayIconLinux.png`. Unset lets the launcher auto-detect Cinnamon dark-panel themes ([#604](https://github.com/aaddrick/claude-desktop-debian/issues/604)). See [Tray icon](#tray-icon-claude_tray_use_dark_icon). |

Since the v3.0.0 rebase onto the official Linux build, launcher policy is opt-in only: no default flag shadows an official code path. Several 2.x variables are therefore gone — see [Removed in v3.0.0](#removed-in-v300).

## MCP Configuration

Model Context Protocol settings are stored in:

```
~/.config/Claude/claude_desktop_config.json
```

**Quit Claude Desktop before hand-editing this file, then reopen it.** The app rewrites the config on its own schedule while running, so edits made while it is open are clobbered on its next config write. `mcpServers` entries that were present at startup are loaded and survive restarts — the loss window is only hand-edits made against a running app.

Run `claude-desktop-unofficial --doctor` to validate the JSON and see how many MCP servers are configured.

## Wayland Support

On Wayland sessions the launcher picks a display backend per compositor:

| Compositor | Backend | Why |
|------------|---------|-----|
| Niri | native Wayland (auto) | no XWayland support at all |
| Everything else (GNOME, KDE, Sway, Hyprland, COSMIC, …) | XWayland (auto) | XWayland global key grabs still work on most; mature path, broadest compatibility |

By default only Niri is auto-selected for native Wayland. GNOME Wayland stays on XWayland by default even though mutter no longer honours XWayland global key grabs ([#404](https://github.com/aaddrick/claude-desktop-debian/issues/404)) — flipping the default GNOME session off XWayland is a rendering/IME/HiDPI risk, so it's left opt-in for now.

To route Quick Entry's global shortcut (`Ctrl+Alt+Space`) through the XDG GlobalShortcuts portal on GNOME, opt into native Wayland with `CLAUDE_USE_WAYLAND=1`. On **GNOME ≤ 49** this works after a one-time portal permission dialog (accept it to bind the shortcut). On **GNOME 50 / xdg-desktop-portal ≥ 1.20 it does not work yet**: the newer portal requires apps to declare identity via `org.freedesktop.host.portal.Registry.Register`, which Electron/Chromium doesn't do, so `globalShortcut.register()` fails and the shortcut stays focus-bound. Tracked upstream at [electron/electron#51875](https://github.com/electron/electron/issues/51875).

Override the auto-detection with `CLAUDE_USE_WAYLAND`:

```bash
# Force native Wayland (GNOME portal route, or Sway/Hyprland)
CLAUDE_USE_WAYLAND=1 claude-desktop-unofficial

# Force XWayland (e.g. to override Niri's auto-native, or if native
# Wayland regresses rendering)
CLAUDE_USE_WAYLAND=0 claude-desktop-unofficial

# Or persist either choice
export CLAUDE_USE_WAYLAND=1
```

**Note:** portal-routed global shortcuts only work where the compositor's portal backend implements `org.freedesktop.portal.GlobalShortcuts`. Support is per-compositor and currently uneven — GNOME and KDE implement it (though the app-id requirement above — enforced for GlobalShortcuts since xdg-desktop-portal 1.21 — applies to all desktops, KDE included); wlroots compositors (Sway, Hyprland, Niri) and COSMIC currently ship no GlobalShortcuts backend, so the portal route is a no-op there until their portal gains one.

## GPU (CLAUDE_DISABLE_GPU)

`CLAUDE_DISABLE_GPU=1` makes the launcher pass `--disable-gpu --disable-software-rasterizer` to the official binary — the same workaround as the in-app Settings hardware-acceleration toggle, persisted via the environment instead. When the variable is **unset** and the previous launch died with Chromium's GPU-process FATAL signature ([#583](https://github.com/aaddrick/claude-desktop-debian/issues/583)), the launcher auto-applies the same flags and keeps them applied on subsequent launches (sticky recovery). Set `CLAUDE_DISABLE_GPU=0` to suppress the auto-fallback when retesting hardware acceleration after a driver fix. The flags are also applied automatically inside XRDP sessions. See [troubleshooting.md](troubleshooting.md#repeated-electron-crashes--gpu-process-fatal-583) for the full workflow.

## Password store (CLAUDE_PASSWORD_STORE)

By default the launcher passes **no** `--password-store` flag: the official build's `os_crypt` autodetection owns the keyring decision (it deliberately declines weak persistence on some sessions rather than storing tokens unsafely). `CLAUDE_PASSWORD_STORE` is the documented escape hatch — when set, its value is passed verbatim as `--password-store=<value>` and overrides the autodetect:

```bash
CLAUDE_PASSWORD_STORE=gnome-libsecret claude-desktop-unofficial
```

The doctor reports which mode is in effect (`Password store: upstream os_crypt autodetect (default)` or `forced to <value>`).

## Input method (CLAUDE_GTK_IM_MODULE)

`CLAUDE_GTK_IM_MODULE` is propagated to `GTK_IM_MODULE` for Electron at startup, so a different GTK input module (e.g. `xim`) can be persisted without wrapping every launch. See [troubleshooting.md](troubleshooting.md#keyboard-input-doesnt-work-ibus--gtk-input-method) for symptoms and trade-offs.

## Tray icon (CLAUDE_TRAY_USE_DARK_ICON)

Upstream ships two Linux tray PNGs and normally picks from GTK dark-mode state plus a GNOME check. On Cinnamon, a dark panel can coexist with a light GTK colour scheme, so the wrong (black) icon is selected. When unset, the launcher probes `org.cinnamon.theme` on Cinnamon sessions and sets `CLAUDE_TRAY_USE_DARK_ICON=1` when the theme name looks like a dark panel style (e.g. Mint-Y-Dark-Aqua). Set `1` or `0` yourself to force the light or dark glyph — `0` overrides upstream's own selection too, so it pins the black glyph even on GNOME or under a dark GTK scheme. Any other non-empty value is ignored by the app but still disables the launcher's auto-detect (the launcher logs this and `--doctor` warns about it). Requires a build that includes the `patch_tray_icon_env_override` asar patch; `--doctor` reports which mode is in effect. Interim fix pending [upstream #77170](https://github.com/anthropics/claude-code/issues/77170).

## Cowork

By default the official Linux client runs Cowork as a helper daemon driving QEMU/KVM. For hosts that can't do KVM (see the [bubblewrap fallback](#bubblewrap-fallback-cowork_vm_backendbwrap) below), an opt-in flag routes Cowork through a lighter sandbox instead. The full stack the default KVM path needs on the host:

| Component | Requirement | Doctor check |
|-----------|-------------|--------------|
| KVM | `/dev/kvm` present and read-write (`sudo usermod -aG kvm $USER` if not) | `_check_kvm` |
| vsock | `/dev/vhost-vsock` present (`sudo modprobe vhost_vsock`) | `_check_vhost_vsock` |
| QEMU | `qemu-system-x86_64` (or `qemu-system-aarch64` on arm64) on `PATH` | `_check_cowork_stack` |
| Firmware | OVMF at one of the **hardcoded** probe paths: `/usr/share/OVMF/OVMF_CODE_4M.fd` or `/usr/share/OVMF/OVMF_CODE.fd` (arm64: `/usr/share/AAVMF/AAVMF_CODE.fd`). No env override exists — firmware installed at Fedora/Arch edk2 locations is not found without a compat symlink. Our RPM package's `%post` creates that symlink automatically (CW-1). | `_check_cowork_stack` |
| virtiofsd | On `PATH` or at a well-known off-PATH location (`/usr/libexec/virtiofsd`, `/usr/lib/qemu/virtiofsd`, `/usr/lib/virtiofsd`) | `_check_cowork_stack` |

Run `claude-desktop-unofficial --doctor` — the Cowork Mode section reports each component with a distro-specific install hint and a one-line readiness summary. A missing stack never fails the doctor; the app works fine without Cowork.

### Bubblewrap fallback (COWORK_VM_BACKEND=bwrap)

Some hosts can never satisfy the KVM stack no matter what's installed. The clearest case is **ChromeOS Crostini**: its Termina kernel blocks `vhost_vsock` at the namespace level, so `/dev/vhost-vsock` is absent with no flag or `modprobe` to bring it back ([#772](https://github.com/aaddrick/claude-desktop-debian/issues/772)). On those hosts the KVM Cowork backend is a dead end.

Setting `COWORK_VM_BACKEND=bwrap` opts into a bubblewrap-sandboxed backend that runs Claude Code directly on the host inside a namespace sandbox, with no VM:

```bash
COWORK_VM_BACKEND=bwrap claude-desktop-unofficial
```

To make it persistent — including for launches from the desktop/app menu, which can't carry a per-command environment — put the flag in the launcher config file instead:

```bash
# ~/.config/claude-desktop-debian/environment
COWORK_VM_BACKEND=bwrap
```

The launcher reads `KEY=value` lines from `${XDG_CONFIG_HOME:-~/.config}/claude-desktop-debian/environment` at startup. Only a fixed allowlist of launcher variables is honored — `COWORK_VM_BACKEND`, `COWORK_NODE_PATH`, `CLAUDE_USE_WAYLAND`, `CLAUDE_PASSWORD_STORE`, `CLAUDE_GTK_IM_MODULE`, `CLAUDE_DISABLE_GPU`, `CLAUDE_TRAY_USE_DARK_ICON` — and only when the variable isn't already set, so an explicit `VAR=… claude-desktop-unofficial` on the command line still wins. The file is never executed as shell. `--doctor` reads it too, so diagnostics always match what a launch would see.

How it works: an asar patch (`patch_cowork_bwrap`) short-circuits the KVM support gate and swaps the native VM helper for a bundled Node daemon (`resources/cowork-vm-service.js`) that speaks the same socket protocol as the official helper but backs it with `bwrap` instead of QEMU. Every branch of the patch is gated on this exact flag, so on an unflagged launch every branch evaluates false and the official KVM path runs unchanged — nothing changes for the KVM majority.

Requirements when flagged:

| Component | Requirement | Doctor check |
|-----------|-------------|--------------|
| Node.js | A system `node` (or `nodejs`) on `PATH` providing `fs.statfsSync` (Node >= 18.15 / 16.19) — the bundled Electron binary ships with the RunAsNode fuse off and can't run the daemon itself. Override with `COWORK_NODE_PATH`. | `_doctor_check_bwrap_node` |
| bubblewrap | `bwrap` installed, with unprivileged user namespaces allowed (Ubuntu 24.04+ blocks them via AppArmor — see [troubleshooting.md](troubleshooting.md)) | `_doctor_check_bwrap_fallback` |

Run `claude-desktop-unofficial --doctor` with the flag set to see the bwrap-path diagnostics. Isolation is namespace-level, not a VM — weaker than the KVM default, which is the trade for running where KVM can't. Any `COWORK_VM_BACKEND` value other than `bwrap` is a 2.x knob the official client ignores.

Extra host paths can be exposed to the sandbox via `coworkBwrapMounts` (`additionalBinds` / `additionalROBinds`) in `~/.config/Claude/claude_desktop_linux_config.json`.

> **Note for immutable distros (Fedora Silverblue, Bazzite):** on these
> systems `/home` is a symlink to `/var/home` on the *host*, but the sandbox
> has no such symlink — `$HOME` inside the sandbox is the literal
> `/home/<user>` form. Use the same form in your config
> (for example `"/home/cloud/dev"`, not `"/var/home/cloud/dev"`) so the
> mount is accessible under `~/` inside the sandbox. Both forms are accepted
> by the validator; only the `/home/...` form will appear under `$HOME`.

## Removed in v3.0.0

The v3.0.0 rebase deleted the patches that read these variables. The doctor's legacy-environment check warns when any of them is still set:

| 2.x variable | What replaces it |
|--------------|------------------|
| `CLAUDE_QUIT_ON_CLOSE` | Native setting: **Settings > General > System Tray** (on = close to tray, off = quit). |
| `CLAUDE_MENU_BAR` | Native app setting; the official build keeps the menu bar on by default (the build's MB-1 tripwire watches for an upstream flip). |
| `CLAUDE_TITLEBAR_STYLE` | Nothing — the official build owns its window frame; the topbar shim is gone. |
| `CLAUDE_KEEP_AWAKE` | Nothing — the patch that read it was deleted with the Windows pipeline. |
| `COWORK_VM_BACKEND` | Still read, but only for the value `bwrap`, which opts into the [bubblewrap fallback](#bubblewrap-fallback-cowork_vm_backendbwrap) above. Other values are ignored. |

## Application Logs

Runtime logs are available at:

```
~/.cache/claude-desktop-debian/launcher.log
```

Each launch also logs an `env={...}` block with the session and `CLAUDE_*` variables that drove the display and input decisions, so bug reports carry the context.
