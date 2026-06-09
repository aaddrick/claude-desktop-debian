[< Back to README](../README.md)

# Configuration

## MCP Configuration

Model Context Protocol settings are stored in:
```
~/.config/Claude/claude_desktop_config.json
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_USE_WAYLAND` | unset (auto) | Force the display backend on Wayland: `1` = native Wayland, `0` = XWayland. Unset auto-detects per compositor (only Niri defaults to native Wayland). See [Wayland Support](#wayland-support) below. |
| `CLAUDE_MENU_BAR` | unset (`auto`) | Controls menu bar behavior: `auto` (hidden, Alt toggles), `visible` / `1` (always shown), `hidden` / `0` (always hidden, Alt disabled). See [Menu Bar](#menu-bar) below. |
| `CLAUDE_TITLEBAR_STYLE` | unset (`hybrid`) | Controls window decoration style: `hybrid` (system frame + in-app topbar), `native` (system frame, no in-app topbar), `hidden` (frameless WCO — broken on X11, kept for diagnostics). See [Titlebar Style](#titlebar-style) below. |
| `COWORK_VM_BACKEND` | unset (auto-detect) | Force a specific Cowork isolation backend: `kvm` (full VM), `bwrap` (bubblewrap namespace sandbox), or `host` (no isolation). See [Cowork Backend](#cowork-backend) below. |

### Wayland Support

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
CLAUDE_USE_WAYLAND=1 claude-desktop

# Force XWayland (e.g. to override Niri's auto-native, or if native
# Wayland regresses rendering)
CLAUDE_USE_WAYLAND=0 claude-desktop

# Or persist either choice
export CLAUDE_USE_WAYLAND=1
```

**Note:** portal-routed global shortcuts only work where the compositor's portal backend implements `org.freedesktop.portal.GlobalShortcuts`. Support is per-compositor and currently uneven — GNOME and KDE implement it (though the app-id requirement above — enforced for GlobalShortcuts since xdg-desktop-portal 1.21 — applies to all desktops, KDE included); wlroots compositors (Sway, Hyprland, Niri) and COSMIC currently ship no GlobalShortcuts backend, so the portal route is a no-op there until their portal gains one.

### Menu Bar

By default, the menu bar is hidden but can be toggled with the Alt key (`auto` mode). On KDE Plasma and other DEs where Alt is heavily used, this can cause layout shifts. Use `CLAUDE_MENU_BAR` to control the behavior:

| Value | Menu visible | Alt toggles | Use case |
|-------|-------------|-------------|----------|
| unset / `auto` | No | Yes | Default — hidden, Alt toggles |
| `visible` / `1` / `true` / `yes` / `on` | Yes | No | Stable layout, no shift on Alt |
| `hidden` / `0` / `false` / `no` / `off` | No | No | Menu fully disabled, Alt free |

```bash
# Always show the menu bar (no layout shift on Alt)
CLAUDE_MENU_BAR=visible claude-desktop

# Or add to your environment permanently
export CLAUDE_MENU_BAR=visible
```

### Titlebar Style

Claude Desktop's web UI includes a custom topbar (hamburger menu, sidebar toggle, search, back/forward, Cowork ghost). On Windows / macOS the bundle gates rendering on `display-mode: window-controls-overlay`; on Linux a shim convinces the bundle to render anyway. Use `CLAUDE_TITLEBAR_STYLE` to choose the layout:

| Value | Frame | In-app topbar | Window controls drawn by | Notes |
|-------|-------|--------------|--------------------------|-------|
| unset / `hybrid` | system | Yes | Desktop environment | **Default.** Stacked layout — DE-drawn titlebar on top, in-app topbar below. Topbar buttons clickable. |
| `native` | system | No | Desktop environment | When the stacked layout looks wrong on your DE, or you don't need the in-app topbar. |
| `hidden` | frameless | Yes | Chromium (WCO region) | Matches Windows / macOS upstream config. **Broken on Linux X11** — topbar buttons unresponsive due to a Chromium-level implicit drag region for `frame:false` windows. Kept for diagnostic / Wayland investigation; see [docs/learnings/linux-topbar-shim.md](learnings/linux-topbar-shim.md). |

```bash
# Switch to the bare native experience (no in-app topbar)
CLAUDE_TITLEBAR_STYLE=native claude-desktop

# Or add to your environment permanently
export CLAUDE_TITLEBAR_STYLE=native
```

This setting applies to the main window only. The Quick Entry and About windows are always frameless.

Run `claude-desktop --doctor` to confirm the resolved titlebar style. The doctor output also flags `hidden` mode as broken on Linux and unrecognized values as fallbacks to `hybrid`.

## Cowork Backend

Cowork mode auto-detects the best available isolation backend:

| Priority | Backend | Isolation | Detection |
|----------|---------|-----------|-----------|
| 1 | bubblewrap | Namespace sandbox | `bwrap` installed and functional |
| 2 | KVM | Full QEMU/KVM VM | `/dev/kvm` (r/w) + `qemu-system-x86_64` + `/dev/vhost-vsock` |
| 3 | host | None (direct execution) | Always available |

To override auto-detection:

```bash
# Force bubblewrap (recommended if KVM times out)
COWORK_VM_BACKEND=bwrap claude-desktop

# Force host mode (no isolation)
COWORK_VM_BACKEND=host claude-desktop

# Make permanent via desktop entry override
mkdir -p ~/.local/share/applications/
cat > ~/.local/share/applications/claude-desktop.desktop << 'EOF'
[Desktop Entry]
Name=Claude
Exec=env COWORK_VM_BACKEND=bwrap /usr/bin/claude-desktop %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
EOF
```

Run `claude-desktop --doctor` to see which backend is selected and which dependencies are available.

## Cowork Sandbox Mounts

When using Cowork mode with the BubbleWrap (bwrap) backend, you can customize
the sandbox mount points via `~/.config/Claude/claude_desktop_linux_config.json`
(a dedicated config for the Linux port, separate from the official
`claude_desktop_config.json`):

```json
{
  "preferences": {
    "coworkBwrapMounts": {
      "additionalROBinds": ["/opt/my-tools", "/nix/store"],
      "additionalBinds": ["/home/user/shared-data"],
      "disabledDefaultBinds": ["/etc"]
    }
  }
}
```

| Key | Type | Description |
|-----|------|-------------|
| `additionalROBinds` | `(string \| {src, dst})[]` | Extra paths mounted read-only inside the sandbox. Accepts any absolute path except `/`, `/proc`, `/dev`, `/sys`. |
| `additionalBinds` | `(string \| {src, dst})[]` | Extra paths mounted read-write inside the sandbox. **`src` is restricted to paths under `$HOME`** for security; `dst` is unconstrained. |
| `disabledDefaultBinds` | `string[]` | Default mounts to skip. Cannot disable critical mounts (`/`, `/dev`, `/proc`). Use with caution: disabling `/usr` or `/etc` may break tools inside the sandbox. |

### Distinct host/sandbox paths (`{src, dst}` form)

By default a string entry like `"/opt/tools"` mounts the host path at the
*same* path inside the sandbox. To map a host directory to a different path
inside the sandbox, use the object form `{ "src": "...", "dst": "..." }`.

The most common use case is making `/tmp` persistent across Bash tool calls.
Each Bash invocation spawns a fresh `bwrap` with `--tmpfs /tmp` and
`--die-with-parent`, so the default `/tmp` is wiped between calls. Mapping a
host cache directory onto `/tmp` keeps state across calls without exposing the
host's real `/tmp`:

```json
{
  "preferences": {
    "coworkBwrapMounts": {
      "additionalBinds": [
        { "src": "/home/user/.cache/claude-tmp", "dst": "/tmp" }
      ],
      "disabledDefaultBinds": ["/tmp"]
    }
  }
}
```

`disabledDefaultBinds: ["/tmp"]` is required to remove the default
`--tmpfs /tmp` so the bind takes effect.

The string and object forms can be mixed freely in the same array.

> **Caution:** Mapping `dst` onto a default RO mount (`/usr`, `/etc`, `/bin`,
> `/sbin`, `/lib`, `/lib64`) silently replaces it inside the sandbox; you
> almost never want this, and `--doctor` will warn if you do.

### Security notes

- Paths `/`, `/proc`, `/dev`, `/sys` (and their subpaths) are always rejected
  for both `src` and `dst`
- For read-write mounts (`additionalBinds`), `src` must be under your home
  directory. `dst` has no `$HOME` constraint — that is the entire purpose of
  the object form (e.g. mapping onto `/tmp`)
- The core sandbox structure (`--tmpfs /`, `--unshare-pid`, `--die-with-parent`,
  `--new-session`) cannot be modified
- Mount order is enforced: user mounts cannot override security-critical
  read-only mounts

### Applying changes

The daemon reads the configuration at startup. After editing the config file,
restart the daemon:

```bash
pkill -f cowork-vm-service
```

The daemon will be automatically relaunched on the next Cowork session.

### Diagnostics

Run `claude-desktop --doctor` to see your custom mount configuration and any
warnings about potentially dangerous settings.

## Application Logs

Runtime logs are available at:
```
~/.cache/claude-desktop-debian/launcher.log
```
