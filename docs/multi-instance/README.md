# Multi-Instance Claude Desktop Profiles

Run **multiple isolated Claude Desktop instances in parallel** on the same Linux machine — each with its own login, its own window, its own taskbar icon — while sharing local Claude Code session history, agent-mode sessions, and other read-mostly state across all profiles.

> Tested on Fedora 43 with GNOME on Wayland, claude-desktop wrapper v2.0.5+ (Electron 41). Should work on any Linux desktop where this RPM/DEB build runs.

---

## Why?

The Claude Desktop Electron app uses a `SingletonLock` in its `userData` directory. Launching it twice with the same `userData` just focuses the existing window instead of opening a second one. This guide shows how to run **N parallel instances** by giving each its own `userData` directory, while symlinking the *session-bearing* subdirectories so all instances see the same chat history and Claude Code sessions.

Useful for:

- Multi-monitor workflows (one Claude per monitor)
- Logging into different accounts simultaneously without losing state
- Keeping long-running agent sessions in their own window without losing them when you start something new

---

## Architecture at a glance

| Per-profile (isolated)              | Shared via symlink to main profile   |
| ----------------------------------- | ------------------------------------ |
| `SingletonLock` / `SingletonCookie` / `SingletonSocket` | `local-agent-mode-sessions/` |
| `Cache/`, `Code Cache/`, `GPUCache/`, `Dawn*Cache/`     | `claude-code/`                |
| `IndexedDB/`, `Local Storage/`, `Session Storage/`     | `claude-code-sessions/`       |
| `Cookies`, `Cookies-journal` (encrypted, per-profile)  | `claude-code-vm/`             |
| `Preferences`, `config.json` (incl. `oauth:tokenCache`) | `pending-uploads/`            |
| `claude_desktop_config.json`         | `git-worktrees.json`                 |
| `bridge-state.json` (per-profile)    | `buddy-tokens.json` (daily counter)  |
| `ant-did` (instance UUID)            |                                      |
| `Crashpad/`, `blob_storage/`         |                                      |

The split keeps Electron singleton-locks separate (so parallel windows work) while the JSON-based session stores can be safely shared (multiple readers, one writer at a time — same as a single-instance install).

---

## Quick start

### 1. Create a second profile

```bash
MAIN="$HOME/.config/Claude"
PROFILE="$HOME/.config/Claude-2"
mkdir -p "$PROFILE/tmp"

# Symlink the shared, session-bearing items
for item in claude-code claude-code-sessions claude-code-vm \
            git-worktrees.json local-agent-mode-sessions \
            pending-uploads buddy-tokens.json; do
  ln -sfn "$MAIN/$item" "$PROFILE/$item"
done
```

### 2. Launch with an isolated `userData`

```bash
claude-desktop --user-data-dir="$HOME/.config/Claude-2" \
               --class=Claude-2 --name=Claude-2 &
```

That's it — a second Claude Desktop window opens. It needs its own login on first launch. Repeat with `Claude-3`, `Claude-4`, … for more profiles.

### 3. (Optional) Add a `.desktop` entry so it shows up in your launcher

See [`claude-desktop-N.desktop.template`](claude-desktop-N.desktop.template). Copy to `$HOME/.local/share/applications/claude-desktop-2.desktop` and substitute `N=2`. Run `update-desktop-database $HOME/.local/share/applications/` afterwards.

---

## Detailed walkthrough

### Why we need `--class` and `--name`

By default every Electron Claude window has `WM_CLASS = "claude", "Claude"`. If you launch three profiles, the desktop environment merges them under a single taskbar icon (because they all match the original `claude-desktop.desktop`'s `StartupWMClass=Claude`). That's not what you want.

The flags `--class=Claude-N --name=Claude-N` set the X11 instance class on **child** windows. Combined with a per-profile `.desktop` file containing `StartupWMClass=Claude-N`, the window manager treats each profile as a distinct application.

> **Caveat:** Electron applies `--class` to dialog/sub windows but the **main BrowserWindow** is currently still labelled by Chromium's internal name. If your taskbar still shows the same icon for all profiles, see [WM_CLASS post-launch fix](#wm_class-post-launch-fix-optional) below.

### Per-profile color-coded icons (optional)

If you've added `.desktop` entries with `Icon=claude-desktop-N`, generate tinted icons via ImageMagick:

```bash
# See recolor-icon.sh — it produces six sizes from the system icon.
./recolor-icon.sh 2 100 100 47    # profile 2 — purple/lavender (hue -95°)
./recolor-icon.sh 3 100 100 167   # profile 3 — green           (hue +120°)
./recolor-icon.sh 4 110 160 30    # profile 4 — indigo (boosted) (perceptually purple)
gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor"
```

The numeric arguments after the profile number are ImageMagick's `-modulate brightness,saturation,hue` parameters (`100,100,100` = no change). Hue values: `100` = 0° shift, `200` = +180°, `0` = -180°. Note that perceived color depends on saturation/brightness too — boosting saturation can shift apparent hue (this is why profile 4's `+30°` looks indigo rather than yellow).

### Launching helper script

[`claude-launch`](claude-launch) is a small Bash wrapper that knows how to:

- create a profile if it does not exist (symlinks + `ant-did`)
- copy the OAuth token cache from the main profile **only on first run** (not overwrite an existing one — important if you log into different accounts per profile)
- launch the profile with the right `--class` flag
- list / kill running instances

```bash
claude-launch              # main (Profile 1)
claude-launch 2            # Profile 2
claude-launch all          # 1 + 2 + 3 + 4 in sequence
claude-launch status       # list running instances
claude-launch kill 4       # kill one profile (SIGTERM → SIGKILL fallback)
claude-launch kill-extras  # kill everything except the main profile
```

### Adding the icons to your dock (GNOME)

```bash
# Inspect current favorites
gsettings get org.gnome.shell favorite-apps

# Add Profile 2/3/4 next to the main entry, e.g. via Python
python3 - <<'PY'
import subprocess, ast
favs = ast.literal_eval(subprocess.check_output(
    ['gsettings','get','org.gnome.shell','favorite-apps'], text=True).strip())
i = favs.index('claude-desktop.desktop')
for n, name in enumerate(['claude-desktop-2.desktop',
                          'claude-desktop-3.desktop',
                          'claude-desktop-4.desktop'], 1):
    if name not in favs:
        favs.insert(i + n, name)
subprocess.run(['gsettings', 'set', 'org.gnome.shell', 'favorite-apps',
                '[' + ', '.join(f"'{f}'" for f in favs) + ']'])
PY
```

Other desktops (KDE, XFCE, etc.): use your panel's "add launcher" UI and point it at the `.desktop` file.

---

## The `claude://` link handler problem

`claude.ai`'s OAuth login redirects to `claude://callback?...`. Your browser hands that URL to whatever owns `x-scheme-handler/claude` in xdg-mime. If you have multiple `.desktop` files declaring `MimeType=x-scheme-handler/claude;`, **any of them** can capture the link — usually whichever was registered last. That means OAuth callbacks may end up in the wrong profile.

### Recommended approach: temporary swap during login

```bash
# 1. Before clicking the login link in profile N's window
xdg-mime default claude-desktop-N.desktop x-scheme-handler/claude

# 2. Click "Login" → browser opens dialog → "Open with Claude" → callback lands in profile N

# 3. After login completes, restore the default
xdg-mime default claude-desktop.desktop x-scheme-handler/claude
```

The cookies are stored per-profile, so once login succeeds you don't need the swap again for that profile.

### Firefox-specific tweak (optional, persistent)

Firefox keeps its own protocol-handler table independently of `xdg-mime`. By default it uses `"action": 4` (alwaysAsk) for unknown schemes, which is what makes the dialog appear. If you'd rather skip the dialog and have Firefox always defer to xdg-mime:

1. Quit Firefox completely (otherwise it overwrites the file on exit).
2. Edit `~/.mozilla/firefox/<profile>.default-release/handlers.json` and change

   ```json
   "schemes": { "claude": { "action": 4 } }
   ```

   to

   ```json
   "schemes": { "claude": { "action": 1 } }
   ```

   (`1` = `useSystemDefault`). Now Firefox will silently route `claude://` to whatever xdg-mime says.

3. Start Firefox again.

The temporary-swap method works without this tweak, so do it only if the dialog bothers you.

---

## WM_CLASS post-launch fix (optional)

If after using `--class=Claude-N` your taskbar still shows the orange icon for every profile, the main BrowserWindow is keeping Chromium's default class. You can patch it with `xdotool` immediately after launch:

```bash
sleep 3   # let the window appear
PID=$(pgrep -f 'electron.*--user-data-dir='"$HOME/.config/Claude-N" | head -1)
for wid in $(xdotool search --pid "$PID"); do
  cur=$(xprop -id "$wid" WM_CLASS 2>/dev/null | sed 's/.*= //')
  [[ "$cur" == *mutter-x11-frames* ]] && continue
  xdotool set_window --class "Claude-N" --classname "Claude-N" "$wid"
done
```

This only lasts until the window is closed; rerun on every launch (or wrap it in `claude-launch`).

A persistent fix would require patching `app.asar` to call `BrowserWindow({wmClass: …})` — out of scope for this guide.

---

## Anti-patterns

| Don't                                                            | Do                                                              |
| ---------------------------------------------------------------- | --------------------------------------------------------------- |
| Symlink the **whole** profile dir (`Claude-N` → `Claude`)        | Only symlink the shared subdirectories listed above             |
| Symlink `IndexedDB/`, `Cookies`, `Cache/`                         | Keep these per-profile (LevelDB/SQLite hold exclusive locks)    |
| `pkill claude-desktop` (kills *every* instance)                   | Target by `--user-data-dir` path, e.g. `pkill -f Claude-2`      |
| Reuse the same `--user-data-dir` for two launches                 | Each parallel instance needs its own `userData`                  |
| Skip `update-desktop-database` after adding a new `.desktop`      | Run it; otherwise launchers won't see the new entry             |
| Launch a profile without `--class`                                | Always pass `--class=Claude-N --name=Claude-N`                  |
| Overwrite `oauth:tokenCache` on every launch                      | Copy it only when the target profile has none (first-run sync)  |

---

## Files in this guide

| File                                          | Purpose                                                  |
| --------------------------------------------- | -------------------------------------------------------- |
| [`README.md`](README.md)                      | This document                                            |
| [`claude-launch`](claude-launch)              | Bash launcher script                                     |
| [`claude-desktop-N.desktop.template`](claude-desktop-N.desktop.template) | Sample `.desktop` entry              |
| [`recolor-icon.sh`](recolor-icon.sh)          | ImageMagick recipe for tinted per-profile icons          |

---

## Rolling back

A profile is just a directory under `$HOME/.config/`. To undo everything:

```bash
# Kill any running instances first
pkill -f 'user-data-dir='"$HOME/.config/Claude-2"

# Remove the profile
rm -rf "$HOME/.config/Claude-2"

# Remove the launcher entry
rm "$HOME/.local/share/applications/claude-desktop-2.desktop"
update-desktop-database "$HOME/.local/share/applications/"

# Restore the default link handler if you swapped it
xdg-mime default claude-desktop.desktop x-scheme-handler/claude
```

Your main profile (`$HOME/.config/Claude/`) is never touched — the symlinks point inward, and writes to shared directories happen the same way they would in a single-instance install.
