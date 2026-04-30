# UI — Window Chrome & Tabs

OS-level window frame plus the in-app tab strip and (PR #538) hybrid in-app topbar. See [`../cases/tray-and-window-chrome.md`](../cases/tray-and-window-chrome.md) for related functional tests.

## OS window frame

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Title bar | Top of window | Drawn by DE/compositor; shows app title; right-click opens window menu | KDE-W ✓; Hypr-N ✓ |
| Close button (X) | Top-right (or top-left on GNOME) | Renders, hover state visible, click hides-to-tray ([T08](../cases/tray-and-window-chrome.md#t08--hide-to-tray-on-close)) | — |
| Minimize button | Adjacent to close | Renders, hover state visible, click minimizes | — |
| Maximize / restore button | Adjacent to minimize | Renders, hover state visible, click toggles maximize | — |
| Resize edges (left, right, top, bottom, corners) | Window perimeter | Cursor changes to resize affordance on hover; drag resizes | Wlroots compositors may not show cursor change |
| Window menu (right-click titlebar) | Right-click anywhere on titlebar | Standard window menu (Move, Resize, Close, Always on Top, etc.) | DE-dependent |

## Hybrid in-app topbar (PR #538 builds)

Sits below the OS frame in hybrid mode. Crosses with [T07](../cases/tray-and-window-chrome.md#t07--in-app-topbar-renders--clickable) and [S13](../cases/tray-and-window-chrome.md#s13--hybrid-topbar-shim-survives-omarchys-ozone-wayland-env-exports).

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Hamburger menu | Top-left of topbar | Renders, click opens sidebar | — |
| Sidebar toggle | Adjacent to hamburger | Renders, click collapses/expands sidebar | — |
| Search icon | Center-left | Renders, click opens search overlay | — |
| Back arrow | Center | Renders, greyed out when no history; click navigates back | — |
| Forward arrow | Adjacent to back | Same as back, but for forward history | — |
| Cowork ghost icon | Right of nav arrows | Renders, click opens Cowork tab | The icon is the canonical "is the topbar shim alive" indicator |
| Drag region (gaps between buttons) | Empty space between elements | Drag region behaves correctly — buttons remain clickable, no implicit drag region capturing button clicks | Critical: this is the regression mode in [T07](../cases/tray-and-window-chrome.md#t07--in-app-topbar-renders--clickable) |

## Tab strip (Chat / Cowork / Code)

Sits in the topbar (hybrid) or in the OS-frame area (legacy). Top center.

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| **Chat** tab | Left tab | Renders, click switches to Chat | — |
| **Cowork** tab | Center tab | Renders, click switches to Cowork; ghost icon may indicate Dispatch state | — |
| **Code** tab | Right tab | Renders, click switches to Code; on Linux, may show 403 / sign-in upsell ([T16](../cases/code-tab-foundations.md#t16--code-tab-loads)) | — |
| Active tab indicator | Underline / fill on active tab | Visually distinct from inactive tabs | — |
| Tab badges (e.g. unread count, Dispatch badge) | Top-right of each tab | Render when applicable, dismiss when state clears | — |

## Other window-level UI

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| About dialog | App menu → About | Modal opens with app version, Electron version, license info; close button works | — |
| App menu (macOS-style) | macOS only — N/A on Linux | Not present on Linux; menu items are in window menu instead | — |
| Update prompt | Triggered by upstream update detection | On DEB/RPM, auto-update path is suppressed ([S26](../cases/distribution.md#s26--auto-update-is-disabled-when-installed-via-apt--dnf)). On AppImage, may surface a prompt | — |
| Crash report dialog | Shown after a crash | Dialog explains what happened, offers to file an issue | Capture for Linux specifics — wording may reference macOS Console / Windows Event Viewer paths only |

## Display-server cross-cuts

| Concern | X11 | Wayland (mutter) | Wayland (KWin) | Wayland (wlroots) |
|---------|-----|-------------------|----------------|---------------------|
| HiDPI scaling | `--force-device-scale-factor=N` works | Auto via fractional scaling | Auto via fractional scaling | Auto where compositor supports it |
| Drag-to-snap (Aero-style) | Works under most WMs | mutter snaps | KWin snaps | Compositor-dependent |
| Always-on-top | Window menu | Window menu | Window menu | Compositor-dependent |
| Cursor theme | Inherits from `gtk-cursor-theme-name` | Same | Same | Same |
