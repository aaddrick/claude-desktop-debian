# Upstream report draft: tray icon deaf to color-scheme changes after the first one

**FILED 2026-07-13 as [anthropics/claude-code#77171](https://github.com/anthropics/claude-code/issues/77171).** First-party bug found 2026-07-13 while verifying [`604-tray-panel-theme.md`](604-tray-panel-theme.md) ([#77170](https://github.com/anthropics/claude-code/issues/77170)) on this host. Single-host evidence so far (Nobara 44 / Plasma 6.6.4 / XWayland); the body hedges accordingly. The version field got `N/A — Claude Desktop 1.19367.0` per [`546-mcp-double-spawn.md`](546-mcp-double-spawn.md).

## Title

```
[BUG] Claude Desktop for Linux: tray icon stops reacting to OS color-scheme changes after the first change — portal SettingChanged signals verified firing (KDE Plasma, XWayland)
```

## Form fields

### What's Wrong?

I maintain [claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian), which repackages the official Linux `.deb`. The tray code here is the official `app.asar` bytes, unpatched, so this is a first-party bug. I found this while verifying the tray-contrast report filed alongside it (#77170), so treat them as related.

The tray icon reacts to the first OS color-scheme change after launch, then goes deaf to every change after that.

I want to be honest about the scope up front: this is a single host, single session so far. Nobara 44, Plasma 6.6.4, Wayland session, app on XWayland. I haven't reproduced it elsewhere yet.

Here's what I saw:

- The **first** color-scheme change after launch (dark → light) updated the tray glyph correctly within about 6 seconds. `IconPixmap` luminance went 255 → 0, in place, no icon flicker.
- Every **subsequent** change was ignored. Light → dark, then a full second light/dark toggle cycle. The glyph stayed at luminance 0 for 60+ seconds after each change, polled every 1–2s over DBus.
- The desktop side did its job. `dbus-monitor` captured 14 `org.freedesktop.portal.Settings` `SettingChanged` signals during the cycle, including `org.freedesktop.appearance` color-scheme flipping between `uint32 1` and `2` (plus the legacy string values). The host's `gsettings`/`xsettingsd` mirrors all reflected each change too, and a `SIGHUP` to `xsettingsd` made no difference.
- The app does have a live re-selection path. The main bundle wires `nativeTheme.on("updated")` to the tray rebuild, and the first transition proves that path works at least once.
- Restarting the app re-derives the correct icon immediately (luminance back to 255 under the dark scheme).

Speculation, and I'm flagging it as speculation: the latch looks like it's below the app code, plausibly in Chromium's Linux dark-mode plumbing losing its subscription after the first delivery. But I haven't bisected Electron vs the app, so that's a guess, not a finding.

### What Should Happen?

Every color-scheme change should update the tray glyph, the same way the first one does.

### Error Messages/Logs

```
Nothing logged in ~/.config/Claude/logs/main.log during the stuck transitions.

Desktop side (dbus-monitor, during one toggle cycle):
  14× org.freedesktop.portal.Settings SettingChanged
  org.freedesktop.appearance color-scheme observed as uint32 1 and uint32 2
  gsettings + xsettingsd mirrors updated on every change; SIGHUP to xsettingsd no effect

App side (SNI IconPixmap luminance over DBus):
  change 1 (dark → light): 255 → 0 within ~6s   [correct]
  change 2 (light → dark): stuck at 0 for 60+s   [ignored]
  further toggles:          stuck at 0            [ignored]
  app restart under dark scheme: back to 255      [recovers]
```

### Steps to Reproduce

1. Launch Claude Desktop under a KDE dark scheme, tray enabled.
2. `plasma-apply-colorscheme BreezeLight` — the icon flips. This works.
3. `plasma-apply-colorscheme BreezeDark` — the icon never flips back.
4. Repeat the toggles to confirm the deafness.
5. Restart the app to recover.

To measure it objectively instead of eyeballing, read the StatusNotifierItem `IconPixmap` over DBus and take the mean luminance of the opaque pixels. White glyph reads ~255, black glyph reads ~0, so the stuck state is unambiguous without trusting your eyes on a small tray icon.
