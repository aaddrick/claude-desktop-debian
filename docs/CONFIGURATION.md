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
| `CLAUDE_USE_WAYLAND` | unset | Set to `1` to use native Wayland instead of XWayland. Note: Global hotkeys won't work in native Wayland mode. |
| `CLAUDE_MENU_BAR` | unset (`auto`) | Controls menu bar behavior: `auto` (hidden, Alt toggles), `visible` / `1` (always shown), `hidden` / `0` (always hidden, Alt disabled). See [Menu Bar](#menu-bar) below. |
| `CLAUDE_TITLEBAR_STYLE` | unset (`hybrid`) | Controls window decoration style: `hybrid` (system frame + in-app topbar), `native` (system frame, no in-app topbar), `hidden` (frameless WCO — broken on X11, kept for diagnostics). See [Titlebar Style](#titlebar-style) below. |

### Wayland Support

By default, Claude Desktop uses X11 mode (via XWayland) on Wayland sessions to ensure global hotkeys work. If you prefer native Wayland and don't need global hotkeys:

```bash
# One-time launch
CLAUDE_USE_WAYLAND=1 claude-desktop

# Or add to your environment permanently
export CLAUDE_USE_WAYLAND=1
```

**Important:** Native Wayland mode doesn't support global hotkeys due to Electron/Chromium limitations with XDG GlobalShortcuts Portal. If global hotkeys (Ctrl+Alt+Space) are important to your workflow, keep the default X11 mode.

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
| `additionalROBinds` | `string[]` | Extra paths mounted read-only inside the sandbox. Accepts any absolute path except `/`, `/proc`, `/dev`, `/sys`. |
| `additionalBinds` | `string[]` | Extra paths mounted read-write inside the sandbox. **Restricted to paths under `$HOME`** for security. |
| `disabledDefaultBinds` | `string[]` | Default mounts to skip. Cannot disable critical mounts (`/`, `/dev`, `/proc`). Use with caution: disabling `/usr` or `/etc` may break tools inside the sandbox. |

### Security notes

- Paths `/`, `/proc`, `/dev`, `/sys` (and their subpaths) are always rejected
- Read-write mounts (`additionalBinds`) are restricted to paths under your home
  directory
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
