# Upstream report draft: file-manager entries outlive an uninstall and fail silently (issue #955)

**FILED 2026-10-24 as [anthropics/claude-code#104916](https://github.com/anthropics/claude-code/issues/104916).** Needs the author comment within 3 days to survive the duplicate bot. Upstream half of [#955](https://github.com/aaddrick/claude-desktop-debian/issues/955). The downstream half (stale AppImage paths, missing icon) is fixed launcher-side by FM-1 (`heal_file_manager_entries`). This report covers only what reproduces on Anthropic's own `.deb`, verified on Debian testing with official `claude-desktop` 3.6556.2. CLI-only form fields get `N/A — Claude Desktop 3.6556.2`, per the note in [`546-mcp-double-spawn.md`](546-mcp-double-spawn.md). After filing, the author comment within 3 days keeps the duplicate bot off it.

## Title

```
[BUG] Claude Desktop for Linux: "Send to Claude" / "Open in Claude Code" file-manager entries survive `apt remove` and then do nothing, silently
```

## Form fields

### What's Wrong?

Claude Desktop for Linux writes two file-manager items into the user's home on every start: **Send to Claude** (files) and **Open in Claude Code** (folders). They are Nautilus scripts in `~/.local/share/nautilus/scripts/` and KDE service menus in `~/.local/share/kio/servicemenus/` and `~/.local/share/kservices5/ServiceMenus/`, all marked `X-Claude-Generated=true`.

When the official package is removed, all six files stay, still pointing at the removed binary:

```
[ -x '/usr/lib/claude-desktop/claude-desktop' ] || exit 0            # both scripts
TryExec=/usr/lib/claude-desktop/claude-desktop                       # folder service menu
Exec="/usr/lib/claude-desktop/claude-desktop" --os-entry=folder_verb %f
```

Dolphin keeps listing both items (KF6 service menus don't hide entries whose `TryExec` is missing), now without an icon, because the package's `claude-desktop.png` went with it. Clicking them does nothing: Send to Claude's script hits its `[ -x … ] || exit 0` guard and exits 0, with no message. Nothing ever removes the files. The app only deletes them when the feature is switched off in its settings, and an uninstalled app never runs again.

The same silent no-op happens whenever the executable path baked into the entries stops existing, not just on uninstall: every entry is built from `process.execPath` at start, so any relocation leaves the user with menu items that look fine and do nothing.

### What Should Happen?

After an uninstall, the items should not stay in the file manager. Failing that, a click should say why it can't run instead of exiting silently.

Two possible fixes, either of which would cover it:

- Make the entries clean themselves up: when the guard finds the executable gone, delete the app's own marked entries (`X-Claude-Generated=true`) before exiting. Today the KDE folder menu runs the binary directly, so it would need to go through its script like Send to Claude does.
- Or report the failure, for example with `notify-send`, rather than `exit 0`.

A package `postrm` can't clean per-user files, so the fix has to live in the entries themselves.

### Error Messages/Logs

None. That's part of the problem: the script exits 0, and Dolphin shows nothing.

### Steps to Reproduce

1. On Debian (here: testing/forky, KDE Plasma 6.7.4), install the official `claude-desktop` 3.6556.2 from `downloads.claude.ai`, start it once, quit it.
2. `ls ~/.local/share/nautilus/scripts/ ~/.local/share/kio/servicemenus/` shows `Send to Claude`, `Open in Claude Code`, `com.anthropic.Claude.SendTo.desktop`, `com.anthropic.Claude.OpenInCode.desktop`.
3. `sudo apt remove claude-desktop`.
4. The same files are still there and still reference `/usr/lib/claude-desktop/claude-desktop`, which is gone.
5. In Dolphin, right-click a file: **Send to Claude** is still listed. Right-click a folder → **Actions**: **Open in Claude Code** is still listed. Clicking either does nothing.
6. `NAUTILUS_SCRIPT_SELECTED_URIS=file:///etc/hostname ~/.local/share/nautilus/scripts/Send\ to\ Claude; echo $?` prints `0`, with no window and no message.

### Is this a regression?

No. The file-manager entries are new in 3.x.

### Claude Code Version / Platform / Terminal

`N/A — Claude Desktop 3.6556.2 (official Linux .deb)`

### Operating System

Linux (Debian testing / forky, KDE Plasma 6.7.4)

### Additional Information

Found while fixing the downstream side in [aaddrick/claude-desktop-debian#955](https://github.com/aaddrick/claude-desktop-debian/issues/955). That project repackages the official `.deb` as rpm and AppImage. There the baked-in `process.execPath` is worse: under an AppImage it's the temporary `/tmp/.mount_claude*` path, so the items break as soon as the app quits, not just on uninstall. Two things would help packagers: an `$APPIMAGE`-style stable path when one is available, and the icon named explicitly rather than taken from `basename(process.execPath)`.
