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
| `COWORK_VM_BACKEND` | unset (auto-detect) | Force a specific Cowork isolation backend: `kvm` (full VM), `bwrap` (bubblewrap namespace sandbox), or `host` (no isolation). See [Cowork Backend](#cowork-backend) below. |

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
