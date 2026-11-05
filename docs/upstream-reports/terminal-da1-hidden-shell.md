# Upstream report draft: terminal panel never answers DA1 for a shell started off screen

**Not filed.** Found in official 4.16336.0 bytes ([#966](https://github.com/aaddrick/claude-desktop-debian/issues/966)). The downstream interim fix is `scripts/patches/terminal-da-reply.sh`.

## Symptom

With fish 4.x as the login shell, a terminal tab started by the Run button or `run_in_terminal` stays blank for 10 seconds, then prints:

```
warning: fish could not read response to Primary Device Attribute query after waiting for 10 seconds.
```

A command pasted during the wait is lost and only its Enter arrives, which leaves an empty prompt.

## Mechanism

1. Fish sends `ESC[0c` at startup and around each command, then waits for the reply.
2. The renderer starts the shell before its xterm is fitted (`offsetHeight === 0`), so output accumulates in `pendingReplay` and xterm never sees the query.
3. The replay is written with `replaying` raised, and the renderer's `onData` handler drops terminal reports while it is raised (`x.replaying && Qr(r)`). This correctly stops stale replies reaching a live shell, but here the reply is the one the shell is still waiting for.

## Reproduction outside the app

Running `fish -i --no-config` (4.9.3) on a PTY:

| Strategy | Warning | Bracketed paste |
|---|---|---|
| No reply, paste during the wait | at 13s | lost |
| No reply, paste after the warning | at 10s | runs |
| Reply to every query | none | runs |

## Suggested upstream fix

Answer DA1 while the terminal is unfitted or replaying instead of dropping the report, or answer it in the main process and drop the xterm reply, which is what the downstream patch does.
