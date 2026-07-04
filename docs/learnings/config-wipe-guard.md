# Config-Wipe Recovery — Learnings

`claude_desktop_config.json` (and the per-account Cowork store files)
can be silently replaced by an empty/stub copy because the official
loaders fall back to an empty value on a failed read and every write
serializes the whole in-memory state back over the file. The **primary
fix is launcher-side backup rotation** (`backup_user_config` in
`scripts/launcher-common.sh`) — patch-zero-clean and recovers every
wipe mode. An in-band asar guard (`scripts/patches/config.sh`) exists,
hardened, but is **parked** (not in `active_patches`) after a
contrarian review; see [Why the in-band guards are parked](#why-the-in-band-guards-are-parked).
Issue [#768](https://github.com/aaddrick/claude-desktop-debian/issues/768).

## The wipe mechanism (official 1.18286.0 bytes)

Three cooperating behaviors in the main bundle, verified against the
beautified official `.deb` bundle:

1. **Load-once cache.** The config is read synchronously once at cold
   start (`$ti`, index.js:142373) and cached in a module global
   (`PaA`, via `mc()` 142482). The loader returns `{}` on: a failed
   `accessSync` (**silently** — no log, no dialog), a JSON parse error,
   or a Zod schema rejection of the whole file (the latter two with an
   error dialog).
2. **Whole-file serialize.** Every write path (`setAppConfig` → `arA`
   142559, under a mutex, anchored by the `"Config file written"`
   literal) mutates the cached object and rewrites the entire file from
   it. No read-before-write.
3. **Automatic writes.** The claude.ai renderer mirrors its
   grouping/starring stores into `preferences.epitaxyPrefs` via the
   `AppPreferences` bridge on every launch, so a write is guaranteed
   shortly after startup — the poisoned cache never gets a chance to
   stay unwritten.

One failed load plus one auto-write ⇒ a populated config (MCP servers,
project groupings, trusted folders) becomes a ~1-2 KB stub. Upstream
reports with the same signature: anthropics/claude-code
[#32345](https://github.com/anthropics/claude-code/issues/32345)
(Linux, from our install base),
[#34359](https://github.com/anthropics/claude-code/issues/34359),
[#56296](https://github.com/anthropics/claude-code/issues/56296),
[#59640](https://github.com/anthropics/claude-code/issues/59640)
(`epitaxyPrefs` groupings, 9.5 KB → 1.7 KB),
[#63651](https://github.com/anthropics/claude-code/issues/63651)
(macOS auto-update loses `spaces.json`).

## Where the renderer state actually lives

Established while root-causing #768 (empty Cowork Projects panel after
the 2.x → 3.0.0 lineage crossover; self-healed on second launch):

- **Cowork project list**: a local file,
  `local-agent-mode-sessions/<accountId>/<orgId>/spaces.json` — not a
  network fetch (the app logs `[Spaces] Loaded N spaces`).
- **Groupings/starring source of truth**: zustand stores persisted in
  the claude.ai origin's IndexedDB (`keyval-store` → `pin-state`),
  behind a one-time destructive localStorage → IndexedDB migration.
- **Mirrors**: `persisted.*` localStorage keys, and on desktop
  `preferences.epitaxyPrefs` via the prefs bridge.
- Every hydration failure in that chain is silently swallowed
  (`catch { return null }`), so a transiently slow IndexedDB (e.g.
  first launch after a multi-major Electron jump) hydrates the stores
  empty and the sync hooks then mirror the empty state into
  `epitaxyPrefs`. Data is never deleted from IndexedDB — which is why
  #768 self-healed on relaunch.

The racing renderer code is served live from claude.ai and cannot be
patched. #768's *own* evidence — "project data verifiably intact on
disk," self-heal on restart — means the disk files were **not** wiped
there; the transient empty was read-side, in code we can't touch. The
config `epitaxyPrefs` mirror *was* written empty and self-healed. So
the on-target in-band rule for #768 is R3 (below), not the
poisoned-cache stub.

## The primary fix: launcher backup rotation (`backup_user_config`)

Runs in the launcher before Electron starts (after `heal_autostart_entry`
in the deb/rpm/AppImage launcher bodies). It rotates out-of-band copies
of `claude_desktop_config.json` and the three Cowork stores
(`spaces.json`, `remote-session-spaces.json`, `scheduled-tasks.json`,
globbed under the nested account/org dirs) into
`${XDG_CACHE_HOME:-~/.cache}/claude-desktop-debian/config-backups/`,
keeping the last 5 per file, rotating only on a real change.

Because it runs at launch, it captures the *previous* session's good
state; an in-session wipe lands as the new `.1` while the good copy
shifts to `.2` and stays recoverable. Why this is the primary fix and
not the asar guard:

- **Patch-zero-clean.** It lives entirely in the launcher, so the
  official `app.asar` still ships byte-identical (D-002).
- **Covers every wipe mode**, including the three the in-band guards
  miss: corrupt-JSON cold start, ENOENT (the #63651 auto-update mode),
  and a single-bad-entry Zod throw. Recovery is a file copy, not an
  in-band heuristic that has to distinguish wipe from intent.
- **Cross-platform-agnostic and reversible.** The user (or a future
  `--doctor --restore`) copies a backup back; nothing is guessed.

Recovery today is manual: copy the newest backup that still has your
data (e.g. `…/config-backups/claude_desktop_config.json.2`) back over
the live file with the app closed.

## Why the in-band guards are parked

A contrarian review (2026-07-04) stress-tested the two asar guards and
demoted both:

- **`local-stores.sh` was deleted.** Its rule — skip the write when the
  on-disk file does *not* `JSON.parse` — misses the failure the loader
  actually produces. The spaces loader `eQn` (index.js:335630) does
  `WBn.parse(JSON.parse(t))`: `JSON.parse` **succeeds**, then the Zod
  `WBn.parse` **throws** on one malformed entry → empty Map → wipe,
  over a file that is still valid JSON. The guard never fires on that.
  It caught only byte-level truncation, which no cited issue exhibits.
  (Separately, the remote-session loader `rQn` 335644 already does
  per-entry `safeParse`+`continue`, so it barely wipes at all.) If this
  is ever worth an in-band fix, do it in the **loader** — salvage-parse
  each entry with `safeParse`+skip, exactly as `rQn` already does — not
  at the writer.
- **`config.sh` stays, hardened but unwired.** It is on-target for
  #768's config symptom (R3), but a data-loss bug identical on Windows
  (#59640) and macOS (#63651) is not a Linux gap, so wiring it bends
  D-002; the launcher backup is the contract-clean primary. It is kept
  ready-to-arm in case the backup proves insufficient.

## The parked config guard: semantics

Three restore rules, applied to a lazy **clone** of the outgoing
object so the live cache (`PaA`) is never mutated — a wrong restore
touches only the bytes on disk, never session state (this removes the
sticky-trap the review flagged). Fail-open on any error.

| Rule | Fires when | Safe because |
|------|-----------|--------------|
| R1 | a top-level key exists on disk but is absent from the outgoing object | no code path legitimately deletes a top-level key — deletions (e.g. `setMcpServers`) keep the key present with fewer entries |
| R2 | same, per `preferences.*` key | preference keys are only ever set, never deleted |
| R3 | outgoing `epitaxyPrefs` is present but **every** value is deep-empty while disk has non-empty values | a live session carries non-empty numeric view state (`rowSplit`, `version`) in `desktop-frame.paneStore.v1`, so all-empty only occurs when hydration failed |

The 2.x-era #400 patch (`Object.assign({}, onDisk, inMemory)` on
`mcpServers`) must **not** return: CF-1 (2026-07-03, in
[`official-deb-rebase-verification.md`](official-deb-rebase-verification.md))
showed 1.18286.0 deletes server entries programmatically, so an
unconditional merge resurrects legitimately deleted servers. The guard
never fires on entry-level deletions. The #400 scenario proper
(hand-editing the file while a healthy session runs) stays unfixed —
the cache is populated there, needs upstream delete-tracking.

### Parked-guard blind spots (documented, fail-open)

- **Corrupt-JSON cold start (loader mode 2).** At write time the guard
  re-parses the still-corrupt disk file; its own `JSON.parse` throws,
  so it fails open and the stub is written. Acceptable — corrupt bytes
  hold no recoverable structured data. (The launcher backup *does*
  cover this: the last good copy predates the corruption.)
- **Persistent read failure (mode 1 not recovered by write time).**
- **R3's `epitaxyPrefs` schema is `ZodUnknown`** (`Xa = wv.create` →
  `ZodUnknown`, index.js:57376) — no shape constraint. R3's "live
  sessions carry numeric view state" invariant is an observation of
  the *current* claude.ai renderer, served live and changeable
  server-side with no bundle change to warn us. If a genuinely
  all-empty-but-intentional epitaxy state ever ships, R3 restores it
  (disk-only now, not sticky). Rare; the launcher backup is the real
  safety net.

## Verifying the parked guard

The anchor regexes follow [`patching-minified-js.md`](patching-minified-js.md)
(`[$\w]+` identifier classes, literal `"Config file written"` anchor,
dynamic identifier extraction, exactly-one match assertion, `_cdd_dc`
idempotency marker, function-form `replace` so `$&` in the snippet
can't be interpolated). An anchor miss returns non-zero (CFG-1) — moot
while parked, but a deliberate fail-loud if ever re-armed.

```bash
# anchor extraction against the shipped minified bytes
grep -oP 'await \K[$\w]+(?=\([$\w]+,\s*[$\w]+\)\s*,\s*[$\w]+\.info\("Config file written"\))' \
    app.asar.contents/.vite/build/index.js   # → ji on 1.18286.0

# after patching: one injection, valid syntax, cache never mutated
grep -o '_cdd_dc' app.asar.contents/.vite/build/index.js | wc -l   # → 7
node --check app.asar.contents/.vite/build/index.js
```

The restore logic is a pure function (`(path, cfg) → restored-or-same
object`), so it unit-tests cleanly against fixtures — including a
non-stickiness assertion that the passed-in cache object is never
mutated and a no-op returns the same reference.
