# UI snapshots

Captured renderer state for the `claude.ai` web view, taken via the
`explore` CLI in [`tools/test-harness/explore/`](../../../tools/test-harness/explore/).
Use these to detect upstream UI drift before it breaks the harness.

The snapshot JSON files themselves are gitignored
(`docs/testing/ui-snapshots/*.json`) — they're noisy diffs and
specific to the moment of capture. This directory is checked in so the
path exists; the README + `.gitkeep` are the only tracked files.

## Capture

Requires a running `claude-desktop` build with the main-process
debugger attached on port 9229 (Developer menu → Enable Main Process
Debugger). Then, from `tools/test-harness/`:

```sh
npx tsx explore/explore.ts snapshot baseline-code-tab
# → wrote /…/docs/testing/ui-snapshots/baseline-code-tab.json
```

Snapshot names are restricted to `[a-zA-Z0-9._-]`.

## Compare

```sh
npx tsx explore/explore.ts diff baseline-code-tab after-feature-x
```

Add `--json` for machine-readable output. Add `--exit-on-diff` to fail
the process (exit code 3) when there are any entries — useful inside a
CI guard.

`diff` arguments accept either a bare name (looked up in this dir,
`.json` appended) or an explicit path.

### What counts as a diff

| Kind      | Meaning                                                 |
|-----------|---------------------------------------------------------|
| `removed` | Element keyed in A absent from B (drift signal).        |
| `changed` | Same key, different visible text or structural detail.  |
| `added`   | New key in B (informational only — surface gained).     |

## Snapshot shape

```jsonc
{
  "capturedAt": "2026-05-02T17:30:00Z",
  "claudeAiUrl": "https://claude.ai/…",
  "appVersion": "1.1.7714",        // from app.getVersion(), null on failure
  "pageState":         { "url", "title", "readyState" },
  "dfPills":           [ /* Chat / Cowork / Code top-level tabs */ ],
  "compactPills":      [ /* env pill, Select-folder pill, … */ ],
  "ariaLabeledButtons":[ /* every <button[aria-label]>, capped at 200 */ ],
  "openMenu":          { "ariaLabelledBy", "ariaLabel", "items": [...] },
  "modals":            [ /* role=dialog with heading + buttons */ ]
}
```

Discovery is by **structural shape**, never by minified Tailwind class
names. See the why-block at the top of
[`tools/test-harness/explore/snapshot.ts`](../../../tools/test-harness/explore/snapshot.ts)
for the rationale.

## Other subcommands

```sh
npx tsx explore/explore.ts            # full snapshot to stdout
npx tsx explore/explore.ts pills      # df-pills + compact-pills + state
npx tsx explore/explore.ts menu       # currently-open menu (or null)
npx tsx explore/explore.ts find <re>  # regex search over text + aria-label
```

`find` regex is case-insensitive by default.
