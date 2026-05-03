# Test-harness AX-tree walker — non-obvious traps

Notes from the v6 → v7 fingerprint migration that switched
`tools/test-harness/explore/walker.ts` from a renderer-side
`document.querySelectorAll` IIFE to Chromium's accessibility tree
(`Accessibility.getFullAXTree` over CDP). All five gotchas below cost
a wasted live-walk to find; capturing them here so the next person
debugging a 0-entry inventory or a redrive cascade can skip the
discovery loop.

## 1. `Accessibility.enable` is async; the first `getFullAXTree` lies

Inspector clients call `target.debugger.sendCommand('Accessibility.enable')`
before the first `getFullAXTree`. Both calls return immediately, but
Chromium populates the AX tree asynchronously — the very first
read can return a tree containing only the `RootWebArea` and a
generic shell (4 nodes total) even when the DOM has hundreds of
interactive elements. The walker's existing `waitForStable` is a
DOM-mutation-quiescence observer with a 1.5s ceiling; on claude.ai's
SPA the DOM mutates constantly so `waitForStable` returns at the
ceiling without the AX tree ever catching up.

**Fix:** `waitForAxTreeStable` polls `getFullAXTree` until two
consecutive reads return the same node count. Called once before the
seed snapshot (with `minNodes: 20` to gate against the 4-node "still
loading" case), once after each `navigateTo` in `redrivePath`, and
baked into every `snapshotSurface` call (with `minNodes: 1` for the
post-click case where the tree is already populated).

**Symptom you'll see:** seed entries: 0. Walker exits with no
inventory. Stderr says `walker: AX tree settled at 4 nodes` (or
similar small number).

## 2. `navigateTo(sameUrl)` is a no-op; redrives carry prior state

The walker's `navigateTo(url)` short-circuits when `currentUrl === url`
(per the original v6 implementation). Every BFS pop re-navigates
to `startUrl` to replay the recorded path against a clean state, but
when `currentUrl` already matches `startUrl` the navigation is
skipped. Anything a prior drill left behind — open dialog, expanded
sidebar, scrolled focus, route params — carries into the next
redrive's snapshots. `clickById` then suffix-matches the requested
fingerprint against a contaminated surface and silently fails to find
elements that were absolutely on the seed surface.

**Fix:** `redrivePath` uses `reloadPage(inspector)` (which evals
`location.reload()` in the renderer) instead of
`navigateTo(startUrl)`. The reload discards the React tree and forces
a fresh mount even when the URL matches.

**Symptom you'll see:** the first one or two BFS items succeed, then
every subsequent redrive fails with
`clickById: no element matches "<seed-id>" on current surface`. The
`<seed-id>` is a button you can verify with the DevTools console is
visibly present.

## 3. claude.ai uses flat `dialog>button[]` and `complementary>button[]`, not `role=list`

The v7 plan's `isListRowChild` check assumes list rows use ARIA list
semantics (`option/listitem` inside `listbox/list`). claude.ai
exposes the connect-apps marketplace as a `dialog` with ~80 plain
`button` children (no `list` wrapper) and the cowork sidebar as a
`complementary` landmark with ~70 plain `button` children. Without
the heuristic those buttons literal-match by name → each gets a
unique stable entry → the BFS queues each individually for drilling
→ inventory bloats from 32 to 442+ entries and most drills fail
because the per-row buttons are virtualized.

**Fix:** `isListRowChild` extended in two ways. (a) `LIST_ROW_ROLES`
includes `button`, `LIST_ANCESTOR_ROLES` includes `group`. (b) A
sibling-count fallback fires when `siblingTotal >= 15` regardless of
ancestor role — sits well above realistic toolbar sizes (≤10) and
well below the smallest claude.ai marketplace (~80). Step 3
(positional fallback) also gates on `!isListRowChild` so list rows
fall through to step 4's `instance` collapse instead of fragmenting
into per-index positionals that can't fold.

**Symptom you'll see:** dialog kind count balloons (>200). One surface
dominates the `surfaceBreakdown` query in the inventory. Each
marketplace card or sidebar row gets its own `kind: structural`
entry with a slugified product name in the id-tail.

## 4. The `more options for X` per-row trigger needs its own shape

Cowork sidebar rows have a "⋮" menu next to each session whose
aria-label is `More options for <session title>`. These don't match
the `cowork-session` shape (which gates on status prefix), so even
after `cowork-session` collapsed the session list, the sibling
"More options for" buttons still emitted individually. Same for any
future per-row action button claude.ai adds.

**Fix:** new `INSTANCE_SHAPES` entry `row-more-options` with regex
`/^More options for /` and matching pattern. Generic enough to cover
any per-row trigger that follows the `<verb> for <row title>` shape.

**Symptom you'll see:** after fixing (1)-(3), a fresh wave of
redrive failures all matching `more-options-for-X` slugs.

## 5. Sidebar virtualization causes structural redrive misses; bump the threshold

claude.ai's cowork sidebar appears to virtualize the session list:
each fresh page load exposes a slightly different subset of sessions
in the AX tree (subset, not just ordering — actually different
membership). The walker captures session N at seed time but on
redrive after `reloadPage` session N may not be in the tree. Each
miss counts toward `MAX_CONSECUTIVE_LOOKUP_FAILURES`, and a stretch
of 25+ consecutive cowork-row redrives can blow through the original
threshold without the renderer being meaningfully wedged.

**Fix:** threshold bumped 25 → 75. The timeout counter (still 5
strikes) gates against actual renderer hangs; the lookup-failure
counter is more about "discovered DOM has drifted from seed", and on
a virtualized list a generous threshold is correct. Subtree pruning
(already in place) keeps the bursts from compounding by dropping
queue items whose path shares the failed step's prefix.

**Symptom you'll see:** the walker aborts mid-walk with
`25 consecutive redrive lookup failures` and the failed ids all
share a common ariaPath prefix (`root.complementary.button-by-name.X`).

## Driver: prefer `walk-isolated.ts` over `explore walk`

`npm run explore:walk` connects to whatever Node inspector is on
:9229 — i.e. the host Claude Desktop the user is currently using.
That mutates the host profile (visited surfaces, navigation history,
route changes) and races with the human at the keyboard.

`tools/test-harness/explore/walk-isolated.ts` mirrors what H05 / U01
do: kills any running host instance, copies auth into a tmpdir
(`createIsolation({ seedFromHost: true })`), spawns a fresh Electron
with isolated `XDG_CONFIG_HOME`, attaches the inspector via
`SIGUSR1`, runs the walk, tears down. Same flag set as
`explore walk` plus `--no-seed` for the rare case you want a
fresh-sign-in run. Use it.
