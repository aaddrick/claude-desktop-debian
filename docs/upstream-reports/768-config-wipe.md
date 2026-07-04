# Upstream report: config + Cowork store stub-wipe (issue #768)

**Status: FILED 2026-07-04** — [anthropics/claude-code#74288](https://github.com/anthropics/claude-code/issues/74288). Survival follow-through per the issue-survival playbook: post an author comment and confirm `has repro` framing within 3 days, and rally upvotes (10+ buys auto-close immunity) — its four predecessors all died to the dupe bot without it.

This is the draft for the upstream bug report covering [#768](https://github.com/aaddrick/claude-desktop-debian/issues/768). Filing target is `anthropics/claude-code` GitHub Issues. This one has been reported at least four times and closed each time without the mechanism traced, so the goal here is to hand the team the actual code lines and a reopen case.

## Template mismatch note

The `anthropics/claude-code` bug template is built for the Claude Code CLI, not Claude Desktop. Required fields like "Claude Code Version" and "Terminal/Shell" don't apply cleanly. Other Claude Desktop bug reports in the same repo work around this by putting `N/A — Claude Desktop <version>` in the version field and selecting `Other` for terminal (see #43705, #36319, #14807).

## Title

```
[BUG] Claude Desktop 1.18286.0: populated claude_desktop_config.json and Cowork stores silently replaced by empty stub after one failed cold-start load
```

## Form fields

### Preflight Checklist

- [x] I have searched existing issues and this hasn't been reported yet
- [x] This is a single bug report
- [x] I am using the latest version of Claude Code

### What's Wrong?

I maintain [claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian), which repackages Anthropic's official Linux `.deb` into the formats you don't serve (RPM, AppImage, Nix, AUR). I was root-causing a config-loss report on our side and traced it to code in the official 1.18286.0 bundle. This has been filed against you at least four times and closed each time without a fix. I think it keeps getting closed because nobody attached the mechanism. Here it is.

There are two surfaces. They're the same bug.

**Surface 1 — `claude_desktop_config.json` gets stubbed.** The config is read once at cold start (`$ti`, index.js:142373) and cached in a module global (`PaA`, via `mc()` at 142482). That loader returns `{}` on all of: a failed `accessSync` (**silently** — no log, no dialog), a `JSON.parse` throw, or a Zod schema rejection of the whole file. The last two at least show an error dialog. The silent `accessSync` failure is the dangerous one.

Every settings write (`arA`, 142559, anchored by the `"Config file written"` log) serializes the whole cached object back over the file under a mutex. There is no read-before-write. So whatever is in the cache is what hits disk.

The claude.ai renderer mirrors its grouping and starring state into `preferences.epitaxyPrefs` on every launch through the `AppPreferences` bridge. That guarantees an auto-write shortly after startup. So the poisoned `{}` cache never gets a chance to sit unwritten.

Net result: one failed cold-start load plus one auto-write, and a populated config (mcpServers, project groupings, trusted folders) is replaced by a ~1-2 KB preferences stub. The file-size signature we've seen in the wild is 9.5 KB going to 1.7 KB.

**Surface 2 — the per-account Cowork store files.** `spaces.json`, `remote-session-spaces.json`, and `scheduled-tasks.json` live under `local-agent-mode-sessions/<accountId>/<orgId>/` and share the same load-once-swallow plus whole-file-rewrite shape. The spaces loader `eQn` (335630) does `WBn.parse(JSON.parse(t))`. That's a throwing Zod parse. One malformed entry makes the whole load return an empty Map, and the next persist writes `{spaces:[]}` over the file. Worth calling out the amplifier: `JSON.parse` succeeds, so the bytes are still valid JSON. It's the Zod layer on top that throws.

The fix pattern already ships in the same file. The remote-session loader `rQn` (335644) does per-entry `safeParse` plus `continue`, so it drops only the bad entry instead of zeroing the file. `eQn` and the scheduled-tasks loader just don't use it.

One more thing while you're in this code. `preferences.epitaxyPrefs`'s own schema is `ZodUnknown` — no shape constraint. Nothing validates or bounds what the renderer mirrors there.

### What Should Happen?

A failed or partial load should never cause a populated file to be overwritten with an empty one. A single bad entry should cost you that one entry, not the whole file.

I'm not going to prescribe one fix. Any of these would close it:

1. **Read-then-merge before serializing.** Preserve on-disk keys the in-memory state doesn't have. This is the general version.
2. **Delay the first write until hydration is confirmed.** Don't let an unhydrated `{}` cache reach the disk.
3. **Keep versioned backups of the preferences file.** Chromium's own `Preferences` file does exactly this next to a `Preferences.bak` — the pattern is already in the tree you ship.
4. **Split grouping state into its own append-mostly file** so a bad preferences write can't take it out.

For the Cowork stores specifically, the minimal fix is to make `eQn` and the scheduled-tasks loader salvage-parse per entry exactly as `rQn` already does. One malformed entry drops one entry instead of zeroing the file. You already wrote the correct version once.

### Error Messages/Logs

The silent `accessSync` path logs nothing, which is part of why this is hard to catch. The two loud paths show an error dialog and the write path logs on success. Grep `~/.config/Claude/logs/` for:

```
"Config file written"      (arA write path, fires on every serialize)
"[Spaces] Loaded N spaces"  (eQn spaces loader — watch for N dropping to 0)
```

The diagnostic signature is file size, not a log line. A `claude_desktop_config.json` that was several KB and comes back under 2 KB after a launch is the tell.

### Steps to Reproduce

The cleanest deterministic trigger drives Surface 1's read-side transient by hand:

1. Linux host running Claude Desktop 1.18286.0
2. Seed a rich `~/.config/Claude/claude_desktop_config.json` (a few mcpServers, some project groupings, trusted folders)
3. Make it transiently unreadable at cold start — `chmod 000` on the file, or introduce a single Zod-invalid key
4. Launch the app, then restore readability (`chmod 644`) while it's running
5. Let the renderer's `epitaxyPrefs` mirror fire on startup

Expected: the config survives. Actual: it comes back a ~1-2 KB stub.

Honest scope note. I have not driven the full authenticated end-to-end wipe headlessly — login is manual on my test VMs, so I couldn't script the renderer half. The write-side mechanism (load-once cache, `{}` fallback, whole-file serialize, guaranteed auto-write) is traced statically in the 1.18286.0 bundle at the line numbers above. The read-side transient in the renderer is confirmed by the #768 reporter: on the first launch after a cross-lineage upgrade the Projects panel rendered empty and `epitaxyPrefs` was written empty to `claude_desktop_config.json`; a second full quit and relaunch repopulated the panel completely, with no data restore and no config edit. I'm not claiming a live end-to-end capture I drove myself, but the loop is observed, not just inferred.

A note on why #768 recovered and the linked reports did not, because it's the crux of the fix. The empty-write mechanism is the same in both. What differs is whether the emptied key has a second source of truth. `epitaxyPrefs` groupings/stars are mirrored *from* the claude.ai-origin IndexedDB (`pin-state`), so a stub write is cosmetic — the next launch re-hydrates and the panel comes back. `mcpServers`, trusted folders, and the Cowork `spaces.json` content have no such backing store; the file *is* the source of truth, so the same stub write is permanent. That is why #32345 (mcpServers) and #63651 (spaces) are real data loss while #768 self-heals — same bug, different blast radius depending on the key.

### Claude Model

Not sure / Multiple models

### Is this a regression?

I don't know

### Last Working Version

(leave blank)

### Claude Code Version

```
N/A — Claude Desktop 1.18286.0
```

### Platform

Anthropic API

### Operating System

Ubuntu/Debian Linux

### Terminal/Shell

Other

### Additional Information

This is not a new report. It keeps landing and keeps getting closed. Same mechanism every time:

- [#32345](https://github.com/anthropics/claude-code/issues/32345) — config stub, filed from a Linux install of my repo, closed "invalid" and locked
- [#34359](https://github.com/anthropics/claude-code/issues/34359) — same, closed
- [#56296](https://github.com/anthropics/claude-code/issues/56296) — same, closed
- [#59640](https://github.com/anthropics/claude-code/issues/59640) — `epitaxyPrefs` groupings wiped on preference write, closed as a dup of #32345
- [#63651](https://github.com/anthropics/claude-code/issues/63651) — auto-update loses `spaces.json`, closed stale
- [#62194](https://github.com/anthropics/claude-code/issues/62194) — still open
- [#74002](https://github.com/anthropics/claude-code/issues/74002) — still open

What those reports lacked and this one supplies: the mechanism traced to code lines, and the observation that the correct salvage pattern (`rQn`'s per-entry `safeParse`) already ships in the same bundle you'd be patching. #59640 being closed as a dup of #32345, and #32345 being closed "invalid," is how a real data-loss bug ends up with no owner. That's the reopen case.

Bundle reference for 1.18286.0. Symbols rename across releases, so each row carries a stable anchor.

| Role | Symbol in 1.18286.0 | Stable anchor |
|---|---|---|
| Config loader (returns `{}` on failure) | `$ti` | index.js:142373 |
| Config module-global cache | `PaA` (via `mc()`) | index.js:142482 |
| Config write path | `arA` | `"Config file written"` (index.js:142559) |
| Spaces loader (throwing Zod parse) | `eQn` | `WBn.parse(JSON.parse(t))` (index.js:335630) |
| Remote-session loader (correct salvage) | `rQn` | per-entry `safeParse`+`continue` (index.js:335644) |
| `epitaxyPrefs` schema | `ZodUnknown` | no shape constraint on the mirror target |

I've shipped a downstream mitigation, but I want to be clear it's a band-aid and not the ask. Since I can't fix the write path from outside `app.asar`, my repackaging runs a launcher-side backup rotation of these four files before Electron starts. It captures the previous session's good state, so an in-session wipe stays recoverable. The durable fix is upstream not serializing an empty in-memory state over a populated file. I'd rather delete my band-aid than keep it.

Full provenance and our tracking: [aaddrick/claude-desktop-debian#768](https://github.com/aaddrick/claude-desktop-debian/issues/768).

## Filing checklist

When you're ready to file:

1. Open https://github.com/anthropics/claude-code/issues/new?template=bug_report.yml
2. Paste each section above into the matching form field
3. Submit
4. Drop the GitHub issue URL as a comment on [#768](https://github.com/aaddrick/claude-desktop-debian/issues/768) so the trail is bidirectional

Note: there is no in-app engineering bug-report path in Claude Desktop. `/bug` and `/feedback` are inert. The Help menu has "Get Support" (routes to the support chat, wrong queue for engineering) and "Troubleshooting" (self-diagnostic — useful for attaching `Copy Installation ID` or `Show Logs in File Manager` output to a GitHub issue, but not a reporting step on its own).

## Voice and authorship

Drafted using the [aaddrick-voice](https://github.com/aaddrick/written-voice-replication/blob/78f178dcf832943bcf1d5a65bf7627c3a20053a6/.claude/agents/aaddrick-voice.md) style profile against the form schema in `anthropics/claude-code/.github/ISSUE_TEMPLATE/bug_report.yml`.

---
Written by Claude Opus 4.8 via [Claude Code](https://claude.ai/code)
