# Quit-cleanup scope fence: two scope namespaces, and no orphaning to clean up

The systemd scope you can trust to identify a Claude Desktop process is the one **Electron creates for itself** (`app-<app-id>-<pid>.scope`), not the one KDE/GNOME creates by desktop-id — and on the current build nothing orphans on quit *or* crash anyway, so the MCP-matching quit-cleanup slice ([#709](https://github.com/aaddrick/claude-desktop-debian/issues/709)) still has no scenario to fix.

```
bare terminal exec of /usr/bin/claude-desktop-unofficial, process → scope:
  app-com.anthropic.Claude-<pid>.scope   MAIN + 3 late utility procs   (4)
  caller's shell scope (konsole tab)     2 zygote + gpu + 1 utility
                                          + 3 renderers                 (7)
```

## Why this exists

[#682](https://github.com/aaddrick/claude-desktop-debian/issues/682) proposed
reaping MCP-ish helper processes (`-mcp`, `@modelcontextprotocol/`) after an
explicit quit, fenced behind a systemd-scope gate that grepped for a literal
`app-claude-desktop-*.scope`. The gate was dead code, so the slice was carved
out and [#709](https://github.com/aaddrick/claude-desktop-debian/issues/709)
opened to gather evidence before it comes back. First-party testing on the
current build (`claude-desktop-unofficial` 1.19367.0-3.2.1, KDE Plasma 6 /
Wayland / systemd 258) established the facts below; they overturned two rounds
of guessed regexes.

## There are two scope creators, and the debate anchored on the wrong one

**KDE/GNOME's KProcessRunner** mints `app-<desktop-id>-<pid>.scope`, but only
for **GUI launches**, and it names the scope by the **desktop-id**:

- It does not exist for terminal launches (the process inherits the caller's
  scope) or autostart launches (those are `.service` template units — see
  below).
- Its name tracks the desktop-id, which the **v3.0.0 package rename changed
  from `claude-desktop` to `claude-desktop-unofficial`**. So the current GUI
  scope is `app-claude-desktop-unofficial-<pid>.scope`, not the historical
  `app-claude-desktop-<pid>.scope` that every proposed regex was pinned to.

**Electron/Chromium itself** calls `org.freedesktop.systemd1`
`StartTransientUnit` on startup and moves its **own pid** into
`app-<app-id>-<pid>.scope`. This is upstream Chromium, not our launcher (the
launcher creates no scopes). Confirm it straight from the shipped binary:

```bash
strings -n 8 /usr/lib/claude-desktop-unofficial/claude-desktop \
    | grep -E 'app-\$1-\$2\.scope|StartTransientUnit|systemd1'
# app-$1-$2.scope
# StartTransientUnit
# org.freedesktop.systemd1
```

This self-scope is the **DE-agnostic, launch-path-agnostic** anchor: it appears
on GUI, terminal, and autostart launches alike, and its app-id
(`com.anthropic.Claude`) is distinctive enough that a user's own MCP dev server
would never carry it.

## The self-scope app-id is versioned — derive it, never hardcode

Case-insensitive, PID-normalized `journalctl --user` history shows the app-id
has changed across releases (an earlier grep for lowercase `claude` **missed**
the capital-C `Claude` scopes entirely — mind the case):

| Unit shape | Line matches | Created by |
| --- | --- | --- |
| `app-claude-desktop-<pid>.scope` | 635 | KDE KProcessRunner (desktop-id), GUI launch |
| `app-claude\x2ddesktop@<hex>.service` | 186 | D-Bus activation |
| `app-claude\x2ddesktop@autostart.service` | 67 | login autostart |
| `app-io.github.aaddrick.claude-desktop-debian-<pid>.scope` | 14 | Electron self-scope, **old** app-id |
| `app-com.anthropic.Claude-<pid>.scope` | 2 | Electron self-scope, **current** app-id |

(Counts are journal line matches, not distinct launches.) The escaping the
KDE half of #709 worried about (`\x2d`) is real, but it only appears on the
`.service` template-instance units (autostart, D-Bus activation), never on a
`.scope`. Any fence must derive the app-id at runtime — same discipline as the
minified-JS [anchor-craft](patching-minified-js.md): literals and dynamic
extraction over pinned names.

## Even the self-scope doesn't contain the helpers on a terminal launch

The browser main self-moves, but the **zygote forks before the move and stays
in the caller's scope**, so everything it descends (renderers, GPU) stays there
too. On a terminal launch the app scope holds the main plus a few
late-spawned utilities; the bulk of the helpers sit in the user's own shell
scope — exactly where a user's own terminal MCP dev server lives. Per-pid scope
membership therefore **cannot** separate a Claude helper from a bystander in the
terminal case. That is the unsolved core of #709's gate 3: matching `-mcp`
cmdlines there risks killing the user's own process.

## No orphaning to clean up — on clean quit *or* crash

The scenario the slice exists for does not reproduce on the current build:

```bash
# fresh launch → 11 electron procs
kill -TERM <main-pid>   # explicit quit  → all 11 gone, nothing orphaned
kill -KILL <main-pid>   # crash sim      → all 11 gone within ~1s
```

Chromium's own process-tree / IPC-channel-death teardown reaps the zygote and
renderers **regardless of which cgroup they sit in**. So the desktop-helper
reaper has no demonstrated survivor to catch. (The cowork daemon is the one
known exception, and it is already handled by
`cleanup_orphaned_cowork_daemon` — see
[`cowork-vm-daemon.md`](cowork-vm-daemon.md).) Until a real survivor surfaces,
the MCP slice stays out; #709 may close itself.

## Testing traps hit along the way

- **`pgrep -f` self-matches.** Any pattern containing `claude-desktop` also
  matches the shell command you are running it from. Resolve real processes via
  `readlink /proc/<pid>/exe` instead:

  ```bash
  for p in $(ls /proc | grep -E '^[0-9]+$'); do
      [[ $(readlink /proc/$p/exe 2>/dev/null) == *claude-desktop-unofficial/claude-desktop ]] \
          && echo "$p"
  done
  ```

- **Detach launches with `setsid … & disown`.** The launcher/Electron emits a
  signal on startup that otherwise aborts the launching shell (exit 144);
  detaching isolates it. `setsid` changes session, not cgroup, so the
  terminal-inherit test stays faithful.

- **A scope existing is not a liveness signal.** A wedged `systemd --user`
  cgroup can outlive the app (`mkdir` EEXIST + `removexattr` ENODATA in a tight
  no-backoff loop — reported on #709), so "is the app scope alive" can return a
  false positive even for the main. Filed upstream at systemd/systemd.
