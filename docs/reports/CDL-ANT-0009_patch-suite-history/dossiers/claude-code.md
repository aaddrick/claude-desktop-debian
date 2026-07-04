# Dossier: Linux Claude Code support patch (`getHostPlatform`)

Unit: `scripts/patches/claude-code.sh` on `main`, single function
`patch_linux_claude_code`, invoked from `patch_app_asar` at
`main:scripts/patches/app-asar.sh:104` under the comment
`# Add Linux Claude Code support`.

## Mechanism

Source: `git show main:scripts/patches/claude-code.sh` (29 lines). The
function operates on `app.asar.contents/.vite/build/index.js` (the minified
main-process bundle) with CWD set by the build orchestrator.

Upstream's `getHostPlatform()` resolver (which decides which Claude Code /
agent binary bundle to fetch for the Code tab) historically returned only
`darwin-*` / `win32-*` and threw `Unsupported platform: linux-x64` on Linux.
The patch splices Linux return branches into that switch.

Concretely:

1. **Idempotency guard** — early-return if the bundle already contains a
   Linux branch:
   ```bash
   grep -q 'process.platform==="linux".*linux-arm64.*linux-x64' "$index_js"
   ```
   (This is the exact string the official-deb audit tool later reuses as its
   necessity probe — see "Fate" below.)

2. **New format path** (comment: `Claude >= 1.1.3541`, arch-aware win32) —
   PCRE detection:
   ```
   if\s*\(\s*process\.platform\s*===\s*"win32"\s*\)\s*return\s+[$\w]+\s*===\s*"arm64"\s*\?\s*"win32-arm64"\s*:\s*"win32-x64"\s*;\s*throw
   ```
   then `sed -i -E` with a `([[:alnum:]_$]+)` capture group that dynamically
   reuses the minified arch variable, inserting before the `throw`:
   ```
   if(process.platform==="linux")return \1==="arm64"?"linux-arm64":"linux-x64";
   ```

3. **Legacy format path** (comment: `Claude <= 1.1.3363`, no win32 arch
   detection) — anchors on
   `if\s*\(\s*process\.platform\s*===\s*"win32"\s*\)\s*return\s*"win32-x64"\s*;`
   and appends
   `if(process.platform==="linux")return process.arch==="arm64"?"linux-arm64":"linux-x64";`
   using `process.arch` directly (no minified variable available in that
   shape).

4. **Fallback** — if neither anchor matches, prints
   `Warning: Could not find getHostPlatform pattern to patch for Linux claude code support`
   and continues (non-fatal; the Code tab would then be broken at runtime).

Runtime effect: the Code tab / Claude Code SDK binary resolution works on
Linux (`linux-x64`, `linux-arm64`) instead of throwing. No globals read or
modified (per the module header).

## Origin

- **First commit:** `5c5eb39` — "Support claude desktop 1.0.1307 with code
  preview", author `jacobfrantz1`, dated **2025-11-28**, merged via **PR
  #143** (merged 2025-11-29). The diff adds an inline block to `build.sh`
  directly after the tray-menu patch:
  ```bash
  # Allow claude code installation
  if ! grep -q 'process.arch==="arm64"?"linux-arm64":"linux-x64"' app.asar.contents/.vite/build/index.js; then
      sed -i 's/if(process.platform==="win32")return"win32-x64";/if(process.platform==="win32")return"win32-x64";if(process.platform==="linux")return process.arch==="arm64"?"linux-arm64":"linux-x64";/' app.asar.contents/.vite/build/index.js
  ```
  i.e. only the "legacy format" single-sed existed at origin.
- **Motivation:** PR #143's body states: "Added logic to support installing
  Linux-specific Claude code binaries, by patching
  `app.asar.contents/.vite/build/index.js` to recognize both `linux-x64` and
  `linux-arm64` architectures." The same PR moved downloads to the
  `claude.ai` redirect endpoint and renamed the native stub to
  `@ant/claude-native` — all adaptations to upstream Claude Desktop
  **1.0.1307**, the release that introduced the Code preview (Code tab).
  Without the patch, upstream's platform switch had no Linux case, so the
  Code tab could not resolve an agent binary on Linux.
- **No motivating GitHub issue found**: PR #143 has empty
  `closingIssuesReferences`, and searches for pre-dating reports came up
  empty (see Gaps).

## Revision history

Substantive changes only, in date order:

1. **`5c5eb39` (2025-11-28, PR #143)** — origin; inline guard + single sed
   in `build.sh` (see above).
2. **`29173e9` (2026-01-22)** — "refactor: organize build.sh into logical
   functions"; the inline block becomes the `patch_linux_claude_code()`
   function. Commit message: "Part of #179" (build-script maintainability
   refactor). Structural, no behavior change.
3. **`db11bd0` (2026-02-19, author Iliya Brook, merged via PR #243)** —
   "fix: update patch_linux_claude_code for Claude >= 1.1.3541",
   `Fixes #241`. Cause per commit message: "Starting with Claude v1.1.3541,
   Anthropic refactored getHostPlatform() to include Windows arm64 support,
   changing the minified code signature. The old sed pattern no longer
   matches, causing the Linux platform patch to silently fail. This results
   in 'Unsupported platform: linux-x64' errors that completely break the
   Code tab." The fix introduced the dual-format detection (new arch-aware
   pattern with a `(\w+)` capture group for the minified variable + legacy
   fallback), a broader idempotency guard
   (`process.platform==="linux".*linux-arm64.*linux-x64`), and the warning
   fallback branch.
4. **`ff4821e` (2026-04-20)** — "refactor: split build.sh into topical
   modules under scripts/"; the function moves verbatim into
   `scripts/patches/claude-code.sh` and gains the module header comment
   ("Linux support in Claude Code's getHostPlatform: route linux-* bundles
   through the normal platform switch instead of throwing"). Commit message
   describes it as a pure-move refactor with byte-identical function bodies.
5. **`3506c14` (merged 2026-05-05, PR #579)** — not a change to the patch
   itself, but the test harness commit added
   `tools/test-harness/src/runners/H03_patch_fingerprints.spec.ts`, which
   asserts the fingerprint `linux-arm64` is present in the built asar:
   "patches/claude-code.sh:20-24 injects `linux-arm64` / `linux-x64`
   platform-bundle branches into getHostPlatform. Upstream throws on Linux;
   the string is absent without the patch." This is the pickaxe hit for
   `getHostPlatform` at `3506c14`.
6. **`b40441c` (2026-05-24, PR #644)** — "fix(patches): harden regex
   patterns for minified JS identifiers". Per the commit message, an audit
   against CLAUDE.md and `docs/learnings/patching-minified-js.md` fixed
   violations in claude-code.sh's "2 format paths": `\w+` → `[$\w]+`
   (PCRE) / `([[:alnum:]_$]+)` (ERE capture) so `$`-containing minified
   identifiers aren't truncated, plus `\s*` whitespace tolerance so the
   patterns also match beautified spacing.

(A pickaxe hit at `073dfec`, 2026-02-16, "Add specialist agents and
writing-agents skill", only mentions the function name inside `.claude/`
agent docs — not a change to the patch.)

## Related issues and PRs

| Ref | Kind | Title | State | Role |
|---|---|---|---|---|
| #143 | PR | Support claude desktop 1.0.1307 with code preview | merged 2025-11-29 | Introduced the patch (origin commit `5c5eb39`) |
| #179 | issue | Refactor build scripts for maintainability and readability | closed | Motivated the `29173e9` function-wrap refactor ("Part of #179") |
| #241 | issue | Claude Code broken after update to v1.1.3541: "Unsupported platform: linux-x64" | closed | Regression report (opened 2026-02-19 by `noctuum`): upstream re-minification rotted the origin anchor; fixed by `db11bd0` |
| #243 | PR | fix: update patch_linux_claude_code for Claude >= 1.1.3541 | merged 2026-02-19 | Delivered `db11bd0` (Fixes #241) |
| #579 | PR | Add Linux compatibility test harness (opt-in, tools/test-harness) | merged 2026-05-05 | Added the H03 fingerprint regression check for this patch |
| #644 | PR | fix(patches): harden regex patterns for minified JS identifiers | merged 2026-05-25 | Regex-hardening revision `b40441c` (2 format paths in claude-code.sh) |
| #357 | issue | Claude Code Preview MCP broken on Linux: Vite 7.x + Node.js 24 IPv6 dual-stack | closed 2026-04-20 | Adjacent Code-tab failure only — handled in the cowork/Code-preview MCP area (`ECONNREFUSED` patch lives in `main:scripts/patches/cowork.sh`), NOT by this unit; listed to delimit scope |

Searches run: `gh search issues 'Unsupported platform linux-x64'` (only
#241), `'"Unsupported platform"'` (#241 + unrelated #259), `'code preview'`
(#357), `'claude code tab'` (no additional relevant hits). No duplicate
reports of #241 found.

## Learnings

- **`docs/learnings/official-deb-rebase-verification.md`** (line 22) —
  carries the patch-necessity matrix row for this unit (quoted below) and
  points at `tools/patch-necessity-audit.sh` for reproduction.
- **`docs/learnings/patching-minified-js.md`** — does not mention this unit
  by name (verified by grep), but it is the guideline document that PR #644
  cites as the basis for hardening this file's regexes; the #241 incident
  (anchor rot from upstream re-minification, silent sed no-match) is exactly
  the failure class that page documents.
- `tools/test-harness` H03 fingerprint spec (from PR #579) encodes the
  patch's detectable fingerprint (`linux-arm64` in `index.js`) as a build
  regression check on main.

## Fate under the official-deb rebase

Matrix row, verbatim from
`docs/learnings/official-deb-rebase-verification.md` (line 22):

> | `claude-code.sh` | **delete** | `getHostPlatform` has a native `linux-x64`/`linux-arm64` branch. |

Byte-level evidence: the doc records an audit of the official Linux `.deb`
**1.17377.2** on 2026-07-02, reproducible with
`tools/patch-necessity-audit.sh`. That tool's `probe_claude_code_platform`
(lines 190–199 in the working tree) greps the official bundle for
`'process.platform==="linux".*linux-arm64.*linux-x64'` — the very string
that was the legacy patch's idempotency guard — and reports
`claude-code.sh not-needed: getHostPlatform has native
linux-x64/linux-arm64 branch`. In other words, the official bytes now
satisfy the patch's own "already present" check natively. Consistent with
this, the teardown (`.tmp/reports/linux-official-teardown/claude-desktop-linux-teardown.tex`,
line 200) records that the official `.deb` ships prebuilt
`node-pty (linux-x64)` "for Code/agent shells" — Code-tab support is
first-class upstream on Linux.

How the NEW build (working tree, branch `rebase/official-deb`) handles it:

- `scripts/patches/claude-code.sh` **no longer exists** — deleted in commit
  `d9cef9e` ("feat(rebase): Phases 1+2 — acquisition swap to the official
  .deb + patch triage"), whose message lists `claude-code.sh` among the
  "11 condemned patches deleted" per the verification matrix. The stat shows
  `scripts/patches/claude-code.sh | 29 -`.
- The rebase branch's `scripts/patches/app-asar.sh` `active_patches` array
  contains only `patch_quick_window` and `patch_org_plugins_path` (lines
  26–29); no claude-code entry, and the module header states the patch-zero
  contract (empty array ⇒ official `app.asar` ships byte-identical).
- No residual references: grep for `claude.code`/`linux-x64` across
  `scripts/setup/official-deb.sh`, `scripts/doctor.sh`, and
  `scripts/launcher-common.sh` on the working tree returns nothing — the
  Code tab needs no launcher/doctor compensation.

The verdict is unconditional (not one of the two "survivor candidate" rows),
and it does not appear in the doc's "Open items" list.

## Gaps

- **No motivating issue for the origin.** PR #143 links no issues and
  searches found no pre-2025-11-28 report of the Code tab being broken on
  Linux; the motivation is reconstructed from the PR body only.
- **Upstream version boundaries are second-hand.** The `>= 1.1.3541` /
  `<= 1.1.3363` format boundaries come from `db11bd0`'s commit message and
  in-code comments; I did not independently diff those upstream bundles.
- **Audit not re-run.** The byte-level evidence is the verification doc's
  recorded 2026-07-02 audit of 1.17377.2 plus the audit script's source; I
  did not execute `tools/patch-necessity-audit.sh` in this session, nor
  live-test the Code tab under the official `.deb`.
- **#357 fix lineage untraced.** It is adjacent (Code Preview MCP /
  cowork.sh territory); which commit closed it was not established here and
  is out of this unit's scope.
