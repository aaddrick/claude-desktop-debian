# Upstream report draft: Linux tray glyph keyed to color scheme, not panel theme (issue #604)

Draft for the upstream bug report covering [#604](https://github.com/aaddrick/claude-desktop-debian/issues/604) and the KDE class datapoint ([#563](https://github.com/aaddrick/claude-desktop-debian/issues/563)-adjacent), verified first-party on official 1.19367.0 bytes. Filing target is `anthropics/claude-code` GitHub Issues; the version field gets `N/A — Claude Desktop 1.19367.0` per the template-mismatch note in [`546-mcp-double-spawn.md`](546-mcp-double-spawn.md). Cross-link [`tray-theme-update-latch.md`](tray-theme-update-latch.md) at filing time (found during this report's verification).

## Title

```
[BUG] Claude Desktop for Linux: tray icon invisible on dark panels when the desktop color scheme is light — glyph keyed to shouldUseDarkColors, panel theme ignored (Linux sibling of #72622)
```

## Form fields

### What's Wrong?

I maintain [claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian), which repackages the official Linux `.deb` into other formats. The tray code here is the official `app.asar` bytes, unpatched, so this is a first-party bug.

The Linux tray glyph is picked from the system color scheme, not from the color of the panel it actually sits on. So on any desktop where the panel theme is independent of the color scheme, you can end up with a black icon on a dark panel. It's effectively invisible.

In the 1.19367.0 main-process bundle (beautified), the Linux selection site is a single ternary:

```js
oPe() === "gnome" || G.nativeTheme.shouldUseDarkColors
  ? "TrayIconLinux-Dark.png"
  : "TrayIconLinux.png"
```

The icon-format switch is baked to `"png"` on Linux, so this is the only Linux selection path. The DE detector `oPe()` splits `XDG_CURRENT_DESKTOP` and returns only `"kde"`, `"gnome"`, or `"other"`. Walking through that:

- **GNOME** gets a hardcoded always-light glyph. That's correct, since GNOME's top bar is always dark.
- **KDE** is detected but never actually used in the ternary.
- **Cinnamon** falls through to `"other"`.

So everyone but GNOME gets the glyph keyed to `shouldUseDarkColors`. But tray visibility depends on the panel color, and on Cinnamon and KDE the panel theme is independent of the color scheme.

I verified it on two desktops.

**Cinnamon:** LMDE 7 / Linux Mint Cinnamon 6.6.7 with the default Mint theme pairing (Cinnamon panel theme `Mint-Y-Dark-Aqua` = dark panel, GTK theme `Mint-Y-Aqua` = light scheme). Result: the black `TrayIconLinux.png` on a dark panel. This came to us as [aaddrick/claude-desktop-debian#604](https://github.com/aaddrick/claude-desktop-debian/issues/604) from @IvanTheGeek, and @mondalaci retested it on 1.19367.0 in our PR #800. A signal that works here: `gsettings get org.cinnamon.theme name` returns `'Mint-Y-Dark-Aqua'` while the color scheme reports light.

**KDE Plasma:** Nobara 44, Plasma 6.6.4, Wayland session (app on XWayland, the default). I pinned the panel dark (`plasma-apply-desktoptheme breeze-dark`) and set the color scheme light (`plasma-apply-colorscheme BreezeLight`; the portal `org.freedesktop.appearance` color-scheme then reads `2`/prefer-light). The tray swapped to the black glyph on the still-dark panel. I measured it over DBus to be sure: the StatusNotifierItem `IconPixmap` mean luminance of opaque pixels went from 255 (white glyph) to 0 (black glyph), same 1679 opaque pixels both times. So it's the same glyph shape with inverted color, not a different asset.

Windows has the same selector defect: [#72622](https://github.com/anthropics/claude-code/issues/72622) (open), glyph keyed to `nativeTheme` instead of the taskbar mode, with earlier [#65343](https://github.com/anthropics/claude-code/issues/65343) and [#41236](https://github.com/anthropics/claude-code/issues/41236) closed. The cross-platform pattern is the same: the icon is chosen from the app/system color scheme instead of the surface it sits on.

### What Should Happen?

The icon should be chosen to contrast with the panel it renders on. A few options, from most correct to cheapest:

1. **Consult the panel-theme signal per DE.** The GNOME special-case already shows this is the design intent, and KDE is already detected in `oPe()`. Cinnamon exposes `org.cinnamon.theme name`; KDE exposes the Plasma style (`plasmarc` `Theme` / `kdeglobals`).
2. **Add a user-facing tray-icon override** ("Invert tray icon", or a light/dark/auto picker) in Settings ▸ General under the existing System Tray toggle. This is cheap, user-recoverable, and covers DEs with no probe-able panel signal, like wlroots compositors.
3. **Ship a monochrome template icon** and let the tray colorize it. That's what #72622 suggests for Windows, and it would collapse all three platforms onto one path.

### Error Messages/Logs

```
(none — the selection is silently wrong-contrast; the only evidence is
visual, plus the DBus IconPixmap luminance probe)

KDE Plasma, over DBus:
  before (dark scheme):  IconPixmap opaque-pixel mean luminance = 255 (white glyph)
  after  (light scheme): IconPixmap opaque-pixel mean luminance = 0   (black glyph)
  opaque pixel count unchanged at 1679 → same shape, inverted color
```

### Steps to Reproduce

KDE Plasma (Wayland or X11):

1. Launch Claude Desktop with the tray enabled.
2. Pin the panel dark: `plasma-apply-desktoptheme breeze-dark`.
3. Set the color scheme light: `plasma-apply-colorscheme BreezeLight`.
4. Watch the tray icon swap to a black glyph on the dark panel.

Cinnamon (default Mint pairing):

1. On Linux Mint Cinnamon / LMDE with the stock `Mint-Y-Dark-Aqua` panel theme and `Mint-Y-Aqua` (light) GTK theme.
2. Launch Claude Desktop with the tray enabled.
3. The black `TrayIconLinux.png` lands on the dark panel.

For what it's worth, we ship an interim launcher workaround downstream (an env flag threaded into the selector, [aaddrick/claude-desktop-debian#800](https://github.com/aaddrick/claude-desktop-debian/pull/800)). Happy to delete it the moment this is fixed upstream.
