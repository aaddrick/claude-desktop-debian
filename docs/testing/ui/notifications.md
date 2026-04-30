# UI — Desktop Notifications

Notification rendering across DEs. The app dispatches notifications via `org.freedesktop.Notifications` (libnotify spec); each DE renders them differently. Related functional tests: [T23](../cases/code-tab-handoff.md#t23--desktop-notifications-fire), [T27](../cases/routines.md#t27--scheduled-task-fires-and-notifies), [S24](../cases/platform-integration.md#s24--dispatch-spawned-code-session-appears-with-badge-and-notification).

## Notification sources

The app posts notifications for the following events. Each should fire reliably on every supported DE.

| Source | Trigger | Expected text | Click action | Notes |
|--------|---------|---------------|--------------|-------|
| Scheduled task fires | When a routine starts a run | "Scheduled task `<name>` started" or similar | Focus the new session in sidebar | Crosses with [T27](../cases/routines.md#t27--scheduled-task-fires-and-notifies) |
| Catch-up run | When a missed run starts after wake | "Catching up on `<name>`" + missed-time hint | Focus the catch-up session | Crosses with [T28](../cases/routines.md#t28--scheduled-task-catch-up-after-suspend) |
| CI status change | When PR's CI state resolves | "CI passed for `<branch>`" or "CI failed: `<check>`" | Focus the session with CI bar | Crosses with [T22](../cases/code-tab-workflow.md#t22--pr-monitoring-via-gh) |
| PR merged (auto-archive trigger) | When watched PR merges | "PR `<title>` merged. Session archived" | — | Crosses with [T30](../cases/code-tab-workflow.md#t30--auto-archive-on-pr-merge) |
| Dispatch handoff | When a Dispatch task creates a Code session | "Dispatch session ready: `<task>`" | Focus the new Dispatch-badged session | Crosses with [S24](../cases/platform-integration.md#s24--dispatch-spawned-code-session-appears-with-badge-and-notification) |
| Permission prompt awaiting approval | When a session in Ask mode needs user approval | "Claude needs your approval" | Focus the awaiting session | Sessions in Ask mode stall until answered |

## Per-notification anatomy

Each notification should include:

| Element | Expected | Notes |
|---------|----------|-------|
| App identity | "Claude" or "Claude Desktop" as the source | DE-specific (Plasma shows the app name and icon prominently) |
| Notification icon | App icon (theme-aware) | Should match the same icon set as the tray |
| Title | Short event headline | One line, no truncation issues for typical lengths |
| Body | One or two short lines of context | Wrap correctly for the DE's notification width |
| Actions (if any) | Inline buttons (e.g. "Open", "Dismiss") | Some DEs show actions, some require expand |
| Click target | Activates the relevant session/window | — |

## Per-DE rendering

| DE / daemon | Expected render | Caveats |
|-------------|-----------------|---------|
| KDE Plasma | KDE notification daemon (KNotifications); appears top-right by default; inline action buttons supported | — |
| GNOME Shell | gnome-shell built-in; appears top-center; limited action support | — |
| Mako (wlroots) | Stacked notifications top-right by default; supports actions if config allows | — |
| Dunst | Lightweight; respects `~/.config/dunst/dunstrc`; actions via keybinds | — |
| swaync (Sway) | Notification center + popups | — |
| Niri | Compositor-provided; usually a portable daemon (mako, dunst) | — |

## Notification persistence

| Element | Expected | Notes |
|---------|----------|-------|
| Notification history | DE-dependent (KDE has notification panel; GNOME has Calendar drawer; mako/dunst can be configured) | Don't rely on persistence — assume fire-and-forget |
| Do-not-disturb mode | Respect DE's DND state | If user has DND on, notifications shouldn't fire — verify the daemon honors this |

## Failure modes to watch for

| Symptom | Likely cause | Diagnose with |
|---------|--------------|---------------|
| No notifications appear | No daemon running; service not registered | `gdbus call --session --dest=org.freedesktop.Notifications --object-path=/org/freedesktop/Notifications --method=org.freedesktop.DBus.Introspectable.Introspect`; `notify-send "test"` from terminal |
| Notification fires but no icon | Icon path resolution failed; theme strip | Inspect the dbus call body for `app_icon` value |
| Click does nothing | Action handler IPC missed; window already focused | Click while main window is hidden — does it appear? |
| Title/body cut off | DE truncation policy | Test with shorter strings to confirm content vs. layout |
| Notifications fire even in DND | Daemon ignoring DND, or our app sets `urgency=critical` inappropriately | Check `urgency` hint in the dbus call |
| Notification persists indefinitely | `expire_timeout=-1` (never) used inappropriately | Confirm timeout passed in the dbus call |
| Per-source duplicates | Multiple subscribers to the same event | Diagnose by isolating one source at a time |
