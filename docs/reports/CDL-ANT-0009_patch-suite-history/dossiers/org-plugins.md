# Dossier: org-plugins Linux path patch (MDM-managed plugin marketplace)

Unit: `scripts/patches/org-plugins.sh` — single function
`patch_org_plugins_path`. One of the youngest patches in the legacy suite
(born 2026-05-24) and one of only two survivors of the v3.0.0
official-deb rebase.

## Mechanism

Read from `git show main:scripts/patches/org-plugins.sh` (57 lines; file
is byte-identical on `rebase/official-deb`, verified via empty
`git diff main..rebase/official-deb -- scripts/patches/org-plugins.sh`).

What it does: upstream's minified `index.js` resolves the org-plugins
source directory (the MDM-managed plugin-marketplace folder used in
third-party/3P inference mode) via a `switch(process.platform)` that has
only `darwin` and `win32` cases; `default:` returns `null`, which every
downstream caller treats as "feature off". The patch splices a Linux case
into that switch so the resolver returns `/etc/claude/org-plugins`.

Concrete steps against `app.asar.contents/.vite/build/index.js` (all
quoted from the main-branch file):

1. **Idempotency guard** — skip if the injected case already exists,
   explicitly anticipating upstream adding native support:
   `grep -q 'case"linux":return"/etc/claude/org-plugins"'`
   ("upstream may add one in the future" per the in-file comment).
2. **Presence probe** — the darwin path string
   `Application Support/Claude/org-plugins` is used as an
   existence check ("unique in the entire bundle" per the comment); if
   absent, the patch warns and skips gracefully:
   `'Warning: org-plugins path resolver not found in this version, skipping' >&2`.
3. **Compound patch anchor** — the insertion point is the byte
   sequence where the win32 case ends and the default begins:
   `grep -qP '"org-plugins"\)\s*;\s*default\s*:\s*return\s+null'`,
   then
   `sed -i -E 's/("org-plugins"\)\s*;\s*)(default\s*:\s*return\s+null)/\1case"linux":return"\/etc\/claude\/org-plugins";\2/'`.
   The comment documents why this anchor is safe: "The compound anchor —
   `"org-plugins")` immediately before `default:return null` — is unique
   to this switch statement", and `\s*` tolerates whitespace variation
   (minified vs. beautified).

There is **no dynamic identifier extraction** — every anchor is a string
literal or keyword, so the patch is immune to identifier re-minification
by construction (consistent with the anchor doctrine later written down
in `docs/learnings/patching-minified-js.md`, though that page does not
cite this patch — my observation, not a documented link).

Path rationale (in-file header comment): `/etc/claude/org-plugins` "is
FHS-correct for MDM-managed configuration, consistent with Claude Code's
`/etc/claude-code/` path."

Wiring on main: `build.sh` sources the module
(`source "$script_dir/scripts/patches/org-plugins.sh"`, added in
337e9a4) and `patch_app_asar` in `scripts/patches/app-asar.sh` calls
`patch_org_plugins_path` under the comment "Add Linux org-plugins path
for MDM-managed plugin marketplace" (same commit).

## Origin

- **First commit**: `337e9a4` — 2026-05-24, "fix(patches): add Linux
  org-plugins path to platform switch", trailer "Fixes #607". It created
  `scripts/patches/org-plugins.sh` whole (57 lines) plus the two wiring
  hunks in `build.sh` and `scripts/patches/app-asar.sh`. Pickaxe
  (`git log --oneline --reverse -S 'org-plugins' main`) confirms no
  earlier ancestry — the patch postdates the ff4821e build.sh split and
  was born as a standalone module, so there is no cross-file archaeology.
- **Motivating issue**: #607 "[bug]: org-plugins setting does not have
  default for linux", opened 2026-05-14 by @johncrn (John Crnjanin),
  labels `bug`, `priority: medium`, `cowork`, `triage: investigated`.
  The reporter ran upstream Claude Desktop **1.7196.0** (repo v2.0.10 per
  the doctor output in the issue), configured 3P inference mode (Azure
  Foundry / AWS Bedrock), and found the plugin marketplace restricted to
  an MDM-managed folder with "specific paths set for Windows and Mac"
  (citing https://claude.com/docs/cowork/3p/extensions#plugin-directory-location)
  while "The case's `default` condition, which is what we land when
  running on linux, returns null." He had already read the code and asked
  for exactly the fix that was implemented. Even a symlink to the
  mac-style folder did not make the marketplace detectable (issue repro
  steps 5–8).
- **Triage corroboration**: the automated triage bot comment on #607
  located the resolver as minified function `pD()` with no
  `case "linux"` branch (`reference-source/.vite/build/index.js:192425-192434`)
  and flagged the precedent `_Ir()` (Claude Code managed-settings path)
  using `/etc/claude-code` as its Linux default — the precedent the
  patch's path choice follows.
- **Delivery**: PR #639 (merged 2026-05-24T21:01:00Z, author @aaddrick,
  attribution "85% AI / 15% Human"), closing #607 the same minute.
  Shipped in release **v2.0.13 — 2026-05-24** (`CHANGELOG.md` line 123:
  "Linux org-plugins path (`/etc/claude/org-plugins`) added to platform
  switch, enabling MDM-managed plugin configuration. (#639, fixes
  #607)").
- Side observation: @johncrn provided the concrete code analysis but does
  not appear in the README Acknowledgments on either `main` or the rebase
  branch (grep for `johncrn`/`Crnjanin` returns nothing), despite the
  CLAUDE.md contributor-credit policy.

## Revision history

Only two commits ever touched the file on main
(`git log --date=short --format='%h %ad %s' main -- scripts/patches/org-plugins.sh`):

1. `337e9a4` — 2026-05-24 12:40 -0400 — introduction (above). Part of
   PR #639 (`gh api repos/.../commits/337e9a4/pulls` → #639).
2. `428777a` — 2026-05-24 12:52 -0400 — "fix(patches): redirect
   org-plugins warnings to stderr". Two-line change appending `>&2` to
   both `echo 'Warning: ...'` skip paths. Also part of PR #639 (same
   `gh api .../pulls` query → #639), i.e. a same-day fixup before merge.
   The commit message states the what; the why is not recorded —
   *inference*: warnings on stdout would pollute build output parsing and
   violate normal stream discipline.

On the rebase branch (not a change to this file, but to its wiring):

3. `d9cef9e` — 2026-07-02 — "feat(rebase): Phases 1+2 — acquisition swap
   to the official .deb + patch triage" rewrote
   `scripts/patches/app-asar.sh` into a thin orchestrator and wired
   `patch_org_plugins_path` into the new `active_patches` array. The
   commit message states: "Survivors wired: quick-window (KDE
   stale-focus) and org-plugins (no linux case upstream)" and "Verified
   end-to-end with an appimage build against official 1.17377.2 amd64:
   both survivors applied on all anchors". `org-plugins.sh` itself is
   byte-identical to main.

No anchor-rot repairs were ever needed: the string-literal anchors
survived every upstream re-minification from 1.7196.0 through official
Linux 1.17377.2 (see #677's attached build log and the rebase audit
below).

## Related issues and PRs

| Ref | Kind | Title | State | Role |
|---|---|---|---|---|
| #607 | issue | [bug]: org-plugins setting does not have default for linux | closed | Motivated the patch; reporter @johncrn supplied the code-level diagnosis. Closed by PR #639. |
| #639 | PR | fix(patches): add Linux org-plugins path to platform switch | merged | Implemented the patch; contains both commits (337e9a4, 428777a). |
| #641 | PR | fix: harden CI, build pipeline, and packaging scriptlets | merged | Search hit only; its single commit ee3d656 does not touch `org-plugins.sh`. The hit comes from a PR *comment* (the body contains no "org-plugins" text): @aaddrick's test-results comment notes the PR's patches "ride on top of main which already includes the … org-plugins fixes". No substantive role. |
| #677 | issue | [bug]: [FAIL] addTrustedFolder anchor not found with Claude Desktop 1.9659.2 | closed | Incidental: attached build log shows "Added Linux org-plugins path (/etc/claude/org-plugins)" succeeding on upstream 1.9659.2 — evidence the anchors survived that re-minification. The failure was in a different patch (claude-code addTrustedFolder). |
| #672 | issue | [bug]: nix build failure on 2ae2172 | closed | Incidental: build log contains the patch's success line only; failure unrelated. |
| #718 | issue | [bug]: nix build failure on d2ce046 | closed | Incidental: same — success line in an attached log; failure unrelated. |
| #396 | issue | Plugin installation fails for all "Anthropic & Partners" plugins — knowledge-work-plugins marketplace not available | closed | Adjacent subsystem, NOT this unit: the remote (claude.ai-served) marketplace install gate documented in `docs/learnings/plugin-install.md`. Listed to disambiguate; no "org-plugins" text in its body/comments. |
| #435 | PR | fix: relax installPlugin gate on Linux for remote marketplaces (#396) | closed | Adjacent subsystem (same disambiguation as #396); closed unmerged as obsolete — @aaddrick's closing comment ("Closing as obsolete — upstream fix supersedes") records that the #396 bug was real on Claude Desktop 1.1.7714 but Anthropic fixed it upstream between 1.1.7714 and 1.3109.0, making the client-side patch unnecessary. |

Remaining `gh search issues 'org-plugins'` hits (#261, #265, #342, #415)
contain no "org-plugins" text in body or comments (verified by grep over
`gh issue view --json body/comments`); they matched only on split
keywords and concern other plugin/cowork subsystems — excluded.

No upstream (anthropics/*) issue for the missing Linux case was found:
`gh search issues --repo anthropics/claude-code 'org-plugins linux'` and
a global search for `org-plugins linux "/etc/claude"` both return empty
(searched 2026-07-03).

## Learnings

- `docs/learnings/official-deb-rebase-verification.md` — the only
  learnings page that mentions this unit (line 30): the patch-necessity
  matrix row quoted verbatim in the next section. The page header states
  every row is reproducible with `tools/patch-necessity-audit.sh` against
  the pinned official 1.17377.2 `.deb`.
- `docs/learnings/plugin-install.md` — the background hint pointed here,
  but verified: it contains **no** org-plugins mention. It covers the
  *adjacent* Anthropic & Partners remote-marketplace install flow (#396),
  where the gate lives in server-rendered claude.ai JS. Useful only to
  distinguish the two plugin subsystems.
- `docs/learnings/patching-minified-js.md` — does not cite this patch,
  but the patch is a textbook instance of its doctrines (string-literal
  anchors over identifiers, idempotency guard, `\s*` whitespace
  tolerance, compound anchor for non-unique tokens). Observation of
  consistency, not documented lineage.

## Fate under the official-deb rebase

**Verdict** (matrix row quoted verbatim from
`docs/learnings/official-deb-rebase-verification.md` line 30):

> | `org-plugins.sh` | **survivor candidate** | The org-plugins path switch has `darwin` and `win32` cases and `default:return null` — **no linux case**, so MDM org plugins are dead on Linux upstream. Keeping the patch preserves our `/etc/claude/org-plugins` behavior; file upstream. |

One of only "2 survivor candidates (≤2 budget holds)" against 11 deletes
(same doc, line 33).

**Byte-level evidence**:

- `tools/patch-necessity-audit.sh` (rebase branch, lines 202–212)
  implements `probe_org_plugins`: if
  `grep -q 'case"linux":return"/etc/claude'` hits, verdict `not-needed`
  ("native linux case in org-plugins path switch"); else if
  `org-plugins` is present at all, verdict `needed?` ("org-plugins
  resolver present, no linux case"). The 2026-07-02 audit of official
  1.17377.2 recorded the latter:
  ".tmp/plans/official-deb-rebase-tracking.md" (Audit highlights):
  "org-plugins switch has NO linux case (`default:return null`) —
  survivor patch + upstream report."
- Live-apply verification, same tracking file: "Both survivor patches
  apply cleanly against official 1.17377.2 bytes: … org-plugins injected
  its linux case."

**How the new build handles it** (working tree, `rebase/official-deb`):

- `scripts/patches/app-asar.sh` lines 26–29:
  `active_patches=(patch_quick_window patch_org_plugins_path)`, with the
  header comment "patch_org_plugins_path — upstream platform switch has
  no linux case, so MDM org plugins are dead on Linux without this
  (filed upstream)". `patch_app_asar` extracts the official `app.asar`,
  runs the array, and repacks preserving upstream's unpacked set; an
  empty array would ship the asar byte-identical (patch-zero contract,
  same file lines 4–7, 66–71).
- `build.sh` still sources `scripts/patches/org-plugins.sh` (lines
  54–55 of the working tree), and the module itself is unchanged from
  main.
- End-to-end: commit `d9cef9e` records an appimage build against
  official 1.17377.2 amd64 where "both survivors applied on all
  anchors".
- Not touched by, and irrelevant to, `scripts/setup/official-deb.sh`
  (acquisition), `scripts/cowork-fallback/` (parked bwrap track),
  `scripts/launcher-common.sh`, and `scripts/doctor.sh` — the unit lives
  entirely inside the asar patch stage (verified: no `org-plugins`
  matches outside `build.sh`, `scripts/patches/{app-asar,org-plugins}.sh`,
  `tools/patch-necessity-audit.sh`, `CHANGELOG.md`, and the learnings
  doc).

**Conditional/open items**: the survivor status is contingent on
upstream continuing to lack a Linux case — the idempotency guard plus
`probe_org_plugins` `not-needed` verdict are the designed retirement
path if Anthropic adds one. The matrix says "file upstream"; that filing
is not yet done (see Gaps).

## Gaps

- **"(filed upstream)" is unsubstantiated.** The `app-asar.sh` comment on
  the rebase branch (line 25) says "filed upstream", but
  `docs/upstream-reports/` contains only `546-mcp-double-spawn.md`, the
  verification doc and tracking plan both phrase it prospectively ("file
  upstream"), and GitHub searches of anthropics repos find no such
  report. Either the filing happened somewhere untracked (e.g. a support
  channel) or the comment is aspirational. Unresolved.
- **No recorded end-user confirmation.** #607 was closed by the merge;
  @johncrn never posted a confirmation that `/etc/claude/org-plugins` is
  actually consumed by the marketplace on a live install. PR #639's test
  plan checks "Verify org-plugins feature is no longer silently disabled
  on Linux", but the evidence behind that checkbox is not in the record.
- **Why 428777a was made** (self-caught vs. review finding) is not
  documented; the stderr rationale above is inference.
- The exact upstream version string in the #672/#718 build logs was not
  extracted; only #677 explicitly ties the patch's success line to
  upstream 1.9659.2.
