# Dossier: node-pty provisioning (install_node_pty + nix/node-pty.nix + package.json optionalDependency)

Unit historian record for the v3.0.0 official-deb rebase. All `main:` references
are to branch `main` of aaddrick/claude-desktop-debian; working-tree references
are to branch `rebase/official-deb` as of commit cafb4cc.

## Mechanism

This unit is **build-time provisioning, not a minified-bundle sed patch**. It
greps/seds no bundle anchors; its job on main is to put a Linux-native
`pty.node` where the upstream Windows-installer `app.asar` expects one, so the
Code tab's integrated terminal (`startShellPty`, which dynamically imports
`node-pty` as an optional dependency — anchors documented in
`main:docs/testing/cases/code-tab-foundations.md` lines 158–163:
"`startShellPty` body: spawns `node-pty` in `n.worktreePath ?? n.cwd`" and
"`node-pty` dynamic import (optional dep, `package.json` line 100)") can load a
native PTY. Four cooperating pieces on main:

1. **`install_node_pty()`** — `main:scripts/patches/cowork.sh` (function starts
   at line 1003). Two acquisition paths:
   - If `--node-pty-dir` was passed (parsed in
     `main:scripts/setup/detect-host.sh` lines 146–157, validated at line 197),
     use that pre-built tree ("Use pre-built node-pty (e.g. from Nix)").
   - Otherwise `npm install node-pty` in an isolated
     `$work_dir/node-pty-build` directory with its own throwaway
     `package.json` (`'{"name":"node-pty-build","version":"1.0.0","private":true}'`)
     — isolation exists so npm doesn't prune other packages such as
     `@electron/asar` (commit bb7c225). npm failure **aborts the build** with
     per-distro toolchain hints ("Debian/Ubuntu: sudo apt install
     build-essential python3") — the fail-loud behavior from 3db7866/PR #598.
   - Staging: `rm -rf "$app_staging_dir/app.asar.contents/node_modules/node-pty"`
     first (wipes the upstream Windows `winpty.dll` / `winpty-agent.exe` /
     PE32+ `.node` files, per the in-code comment citing #401; commit de604e9),
     then `cp -r --no-preserve=mode` of `lib/`, `package.json`, and `build/`
     into `app.asar.contents/node_modules/node-pty/`. `--no-preserve=mode`
     stops Nix-store 0444 bits propagating (commit e92aea1/PR #438). Staging
     `build/` is load-bearing: without a manifest entry for
     `node-pty/build/`, "Electron's asar->.unpacked redirect never fires, so
     `require('../build/Release/pty.node')` from inside the asar fails with
     MODULE_NOT_FOUND" (in-code comment; commit 3150477/PR #421).
   - Idempotency: the `rm -rf`-before-copy makes re-staging idempotent. No
     dynamic identifier extraction — nothing here touches minified JS.

2. **The `optionalDependencies` edit** — `main:scripts/patches/app-asar.sh`
   lines 50–51, inside `patch_app_asar()`:
   `pkg.optionalDependencies = pkg.optionalDependencies || {};`
   `pkg.optionalDependencies['node-pty'] = '^1.0.0';`
   (idempotent via the `|| {}` guard). This makes the app's optional-dep
   dynamic import of `node-pty` resolvable in the repacked asar.

3. **`finalize_app_asar()`** — `main:scripts/staging/electron.sh`. Packs with
   `"$asar_exec" pack app.asar.contents app.asar --unpack '**/*.node'` (line
   20) so `.node` binaries land in `app.asar.unpacked/` AND are recorded as
   unpacked in the manifest, then copies `build/Release/*` from
   `$node_pty_dir` or `$node_pty_build_dir` into
   `app.asar.unpacked/node_modules/node-pty/build/Release/` (lines 32–44;
   acknowledged as redundant-but-harmless in commit 3150477's message).

4. **`nix/node-pty.nix`** — `buildNpmPackage` of `microsoft/node-pty` v1.1.0
   (`rev = "v${version}"`, pinned SRI hashes). Three upstream workarounds,
   each commented in the file: strip the macOS-only `fsevents` reference from
   `package-lock.json` (`sed -i '/"fsevents"/d'`), run **both** `npm run
   build` (tsc) and `node-gyp rebuild` in `buildPhase`, and `postInstall`-copy
   `build/` because `npmInstallHook` skips native addons. Wired via
   `main:flake.nix` lines 14/37 (`callPackage ./nix/node-pty.nix`) and
   `main:nix/claude-desktop.nix` line 94
   (`--node-pty-dir "${node-pty}/lib/node_modules/node-pty"`). When
   `--node-pty-dir` is set, `main:scripts/setup/dependencies.sh` (line 29)
   skips the gcc/g++/make/python3 auto-provisioning.

## Origin

- **First commit: 3591392, 2026-01-05**, "Add node-pty support for Claude Code
  terminal integration" (author aaddrick, Co-Authored-By Claude Opus 4.5),
  merged the same day as **PR #152**. The diff added the npm install + copy
  blocks and the `optionalDependencies['node-pty'] = '^1.0.0'` edit directly
  to the monolithic `build.sh` (pickaxe across the ff4821e/29173e9 module
  splits confirms this is the true origin).
- **Motivation** (PR #152 body): "The macOS version of Claude Desktop includes
  `node-pty` as an optional dependency for terminal integration. The Windows
  version doesn't include it (likely uses ConPTY directly). This PR adds
  node-pty support to the Linux build." — i.e. the Windows-installer
  `app.asar` the project repackaged shipped no Linux `pty.node`, so Code-tab
  shells could not spawn. No motivating issue number appears in the commit or
  PR; it reads as a self-initiated feature enabling Claude Code terminal
  features (inference from the PR body — see Gaps).
  (Note: PR #152's claim that Windows "doesn't include it" was later
  corrected by the #401 evidence — the Windows installer *did* ship node-pty,
  just with Windows-only binaries.)
- **Situation at the time**: the build pipeline downloaded the Windows
  `Claude-Setup-x64.exe` from the unversioned
  `storage.googleapis.com/osprey-downloads-.../nest-win-x64/` URL
  (`3591392:build.sh` line 13); the exact upstream app version at merge time
  is not recorded (see Gaps). At origin the failure path was soft: "if
  node-pty fails to install, a warning is shown but the build continues"
  (PR #152 body) — the softness later became the #401 failure mode.

## Revision history

Substantive changes only, in date order (pure refactors ff4821e "split
build.sh into topical modules" and 29173e9 "organize build.sh into logical
functions" moved the code without changing behavior):

- **3591392 (2026-01-05, PR #152)** — origin, as above.
- **bb7c225 (2026-01-05)** — "Fix node-pty installation removing other npm
  packages": install into a separate directory with its own `package.json`
  "to avoid npm pruning other packages from WORK_DIR (like @electron/asar)"
  (commit message). Same-day follow-up bug fix.
- **31e5aab (2026-01-25)** — consumer-side, not provisioning: rewrote
  `scripts/claude-swift-stub.js` to spawn via node-pty because
  "child_process.spawn() … stdout events" misbehave in Electron (commit
  message). Listed because it made node-pty load-bearing for the
  then-current Cowork stub, not just Code-tab shells.
- **ff9fd3d → daf87a3 → caa58ca → 9fe293d (all 2026-02-26) and 6a3aae6
  (2026-02-28), all @typedrat, merged 2026-03-01 as PR #266** ("feat: add
  NixOS flake with build.sh integration"). Intra-PR order verified:
  `git merge-base --is-ancestor daf87a3 caa58ca` exits 0, and gh lists
  daf87a3 4th vs caa58ca 13th among the PR's commits.
  - ff9fd3d (18:27) created `nix/claude-desktop.nix` with a
    **nixpkgs-sourced `node-pty` input** — its diff adds `node-pty,` to the
    derivation's input list plus an installPhase copy from
    `${node-pty}/lib/node_modules/node-pty/build/Release/`.
  - daf87a3 (18:43) removed that nixpkgs input sixteen minutes later:
    "Remove node-pty dep (not in nixpkgs; terminal features TBD)" (commit
    message) — no such nixpkgs attribute existed, so for a few intra-PR
    commits the Nix build had no node-pty provisioning at all.
  - caa58ca (19:39) filled the gap from source: created `nix/node-pty.nix`
    with the three upstream workarounds (fsevents strip, dual buildPhase,
    postInstall copy) and the v1.1.0 pin all present at creation (verified
    via `git show caa58ca:nix/node-pty.nix`), added `--node-pty-dir`
    parsing to `build.sh`, and "wires node-pty into claude-desktop.nix via
    --node-pty-dir flag" (commit message). This wiring was never removed
    within the PR.
  - 9fe293d (19:50) made the build.sh side consume the flag in
    `install_node_pty` and `finalize_app_asar`: "`--node-pty-dir` … (was
    parsed but never used; nix builds had no node-pty binaries)" (commit
    message).
  - 6a3aae6 review feedback: `-n` guard for `node_pty_build_dir` in
    `finalize_app_asar`'s elif branch, early validation of `--node-pty-dir`
    with clear errors (commit message).
- **3150477 (2026-04-17, @Joost-Maker, merged via 2fd9faf as PR #421)** —
  "mark node-pty native modules as unpacked in asar manifest". Root cause per
  the commit message: the asar manifest had no `node-pty/build/` entry, so
  Electron's asar→`.unpacked` redirect never fired and "Claude Code mode
  shows 'Failed to load terminal backend' on every shell session attempt".
  Two-part fix: stage `build/` in `install_node_pty()` and pass
  `--unpack '**/*.node'` in `finalize_app_asar()`.
- **50b10ed (2026-04-19, @typedrat, PR #432)** — "chmod node-pty unpacked
  files before overwriting in Nix builds": `asar pack --unpack` preserved
  Nix-store read-only perms on extracted `.node` files, making the follow-up
  `cp -r` fail with Permission denied (commit message).
- **e92aea1 (2026-04-19, aaddrick, PR #438)** — "strip mode on node-pty cp at
  source, retire chmod": follow-up to #432 replacing the post-hoc chmod with
  `--no-preserve=mode` on the `install_node_pty()` and `finalize_app_asar()`
  cp invocations (commit message).
- **3db7866 (authored 2026-05-09, @JoshuaVlantis, PR #598 merged 2026-05-14)**
  — fail-loud on `npm install node-pty` failure + add gcc/g++/make/python3 to
  `check_dependencies`; closes "the silent-failure path surfaced during
  testing for #401" where a soft warning "shipped the upstream Windows
  node-pty binaries unchanged" (commit message; verified in an ubuntu:24.04
  container per the message).
- **de604e9 (authored 2026-05-09, @JoshuaVlantis, PR #597 merged 2026-05-24)**
  — "clean upstream Windows binaries before staging Linux build (#401)": the
  `rm -rf` of the upstream-extracted node-pty so orphan PE32+ files
  (`winpty.dll`, `winpty-agent.exe`, Windows `.node`) no longer persist in
  the packed asar; verified with `asar list` on deb and rpm builds (commit
  message). CHANGELOG.md line 141 credits @JoshuaVlantis for the #597 wipe;
  the companion #598 fail-loud change has its own bullet at CHANGELOG line
  172, which names no contributor (that bullet also mislinks issue #401 as a
  `/pull/` URL — a pre-existing CHANGELOG defect, noted here only for
  accuracy).
- **3b86003 (2026-05-14)** — peripheral: re-pinned `electron@41.5.0` after
  PR #587's first commit (cf64b78) dropped the `^41` pin, with node-pty's
  "native surface" cited as part of the ABI-compatibility rationale (commit
  message, "Refs #584. Addresses self-review feedback on #587"). 3b86003 is
  the second of PR #587's own three commits (cf64b78 → 3b86003 → 57cfab8,
  all @aaddrick/Claude), so the drop and the re-pin merged together. Not a
  change to this unit's code, but the pin protected the ABI the compiled
  `pty.node` was built against.

## Related issues and PRs

- **PR #152** (merged 2026-01-05, @aaddrick) — "Add node-pty support for
  Claude Code terminal integration". *Origin PR.*
- **PR #266** (merged 2026-03-01, @typedrat) — "feat: add NixOS flake with
  build.sh integration". *Created `nix/node-pty.nix` and the
  `--node-pty-dir` flow.*
- **Issue #401** (closed, opened 2026-04-15 by @MyenergySPA) — "[bug] Terminal
  fails to load on Fedora RPM — app.asar ships Windows node-pty binaries".
  *Regression report against this unit's soft-failure design; motivated PRs
  #597 and #598.*
- **PR #421** (merged 2026-04-17, @Joost-Maker) — "fix: cowork existsSync
  crash on 1.3109+ and unblock node-pty terminal". *Fixed the asar-manifest
  unpacked-entry bug (commit 3150477) that broke terminal backend loading.*
- **PR #432** (merged 2026-04-19, @typedrat) — "fix: chmod node-pty unpacked
  files before overwriting in Nix builds". *Fixed Nix read-only-perm build
  failure introduced by the #421 `--unpack` change.*
- **PR #438** (merged 2026-04-19, @aaddrick) — "fix: strip mode on node-pty cp
  at source, retire chmod". *Cleanup follow-up to #432.*
- **PR #597** (merged 2026-05-24, @JoshuaVlantis) — "fix(node-pty): clean
  upstream Windows binaries before staging Linux build". *Fixed the #401
  orphan-Windows-binaries half.*
- **PR #598** (merged 2026-05-14, @JoshuaVlantis) — "fix(node-pty): fail
  loudly on npm install failure; require gcc/make/python3". *Fixed the #401
  silent-failure half.*
- **PR #587** (merged 2026-05-14, @aaddrick) — "fix(deps): fetch electron
  binary via @electron/get, drop ^41 pin". *Peripheral: the PR's first commit
  (cf64b78) dropped the Electron pin that guarded pty.node's ABI; its second
  commit (3b86003, "Addresses self-review feedback on #587") restored it
  citing node-pty — the pin was dropped and re-added within the PR before
  merge, so no merged pin-less state ever shipped.*
- **Issue #727** (open, 2026-06-19, @EtherAura) — "Linux: node-pty
  spawn-helper not built → Code-tab integrated terminal shell PTY exits code
  1". *Open defect in this unit's compile-and-stage pipeline: node-pty 1.1.0
  "also forks the shell through a separate build/Release/spawn-helper
  executable" which the legacy build never shipped (issue body). Explicitly
  distinct from #401.*
- **Issue #728** (open, 2026-06-19, @EtherAura) — "Linux: integrated-terminal
  shell hardcoded to powershell.exe → shell PTY exits code 1". *Adjacent
  upstream-bundle defect: even with a working pty.node, the Windows bundle
  spawns `powershell.exe`; co-reported with #727.*
- **PR #761** (open, @LiukScot) — "fix(patches): spawn a working terminal
  shell on Linux (#727, #728)". *Pending fix touching `nix/node-pty.nix`,
  `scripts/patches/cowork.sh`, `scripts/patches/claude-code.sh` — all files
  the rebase deletes or parks; its disposition under v3.0.0 is unrecorded
  (see Gaps).*
- **Issue #385** (closed, 2026-04-08, @filiptrplan) — "Cowork not being
  installed on NixOS". *Peripheral: comment thread cross-references PR #421
  as also fixing "the node-pty asar packaging" alongside the cowork regex
  fix.*

## Learnings

- `docs/learnings/official-deb-rebase-verification.md` (working tree /
  rebase branch) carries this unit's matrix row and verdict (quoted below)
  plus the reproduction hook: "Reproduce any row with
  `tools/patch-necessity-audit.sh`". That tool's `probe_node_pty()` (lines
  286–293) finds `*node-pty*` `*.node` under the extracted official tree and
  reports `'node-pty rebuild' 'not-needed'` when `file` says ELF.
- **No `docs/learnings/*.md` entry on main covers node-pty specifically.**
  A grep of `main:docs/` for `node-pty` matches only
  `docs/testing/cases/code-tab-foundations.md` (test case T19-area, the
  `startShellPty`/dynamic-import anchors cited under Mechanism).
  `docs/learnings/patching-minified-js.md` is about bundle-anchor patches
  and does not discuss this provisioning unit.
- The teardown report (CDL-ANT-0008,
  `.tmp/reports/linux-official-teardown/claude-desktop-linux-teardown.tex`
  line 200) records the official inventory row: "node-pty (linux-x64) &
  prebuilt & native & Pseudo-terminal for Code/agent shells", and line 353
  lists "the node-pty rebuild" among patches retireable by rebasing on the
  official build.

## Fate under the official-deb rebase

**Matrix row, verbatim** (`docs/learnings/official-deb-rebase-verification.md`
line 24):

> | node-pty rebuild + `nix/node-pty.nix` | **delete** | Prebuilt `prebuilds/linux-x64/pty.node` ships in `app.asar.unpacked`. |

Byte-level evidence: the official 1.17377.2 `.deb` (audited 2026-07-02 per the
doc header) ships a prebuilt Linux `pty.node` at
`app.asar.unpacked/.../prebuilds/linux-x64/` — note the newer node-pty
`prebuilds/` layout rather than the legacy `build/Release/` path this unit
compiled into. `tools/patch-necessity-audit.sh:probe_node_pty()` mechanizes
the check (ELF test via `file`). The teardown inventory (CDL-ANT-0008 line
200) independently lists node-pty linux-x64 as prebuilt native.

How the rebase branch (working tree) handles it — all verified in the tree:

- **The whole unit is deleted** in commit d9cef9e ("feat(rebase): Phases 1+2"),
  whose message lists "node-pty rebuild + nix/node-pty.nix" among the "11
  condemned patches deleted" and notes "`--node-pty-dir` dropped".
  Confirmed: `nix/node-pty.nix` is gone (`nix/` contains only
  `claude-desktop.nix` and `fhs.nix`); `install_node_pty` does not exist
  anywhere, including the parked `scripts/cowork-fallback/cowork.sh`; a grep
  of `scripts/`, `nix/`, and `build.sh` for `node-pty|pty.node` finds only a
  historical comment in `nix/claude-desktop.nix` (line 4) telling the Nix
  rewriter to recover the old derivation from git history.
- **No `optionalDependencies` edit remains.** The new
  `scripts/patches/app-asar.sh` only *reads* `productName` from the asar's
  `package.json` (`_asar_package_json_field`, lines 32–43) — the official
  bundle already declares/imports node-pty itself.
- **The repack preserves the official pty.node placement generically.** When
  `active_patches` (currently `patch_quick_window`,
  `patch_org_plugins_path`; lines 26–29) forces a repack, the `--unpack`
  glob is "derived from the shipped app.asar.unpacked tree rather than
  hardcoded" (comment at lines 82–86): `find . -type f` over
  `app.asar.unpacked`, folded into a single brace glob (asar honors only one
  `--unpack` expression), then a post-pack set-equality check that hard-fails
  if "repacked app.asar.unpacked diverges from the upstream unpacked set"
  (lines 101–112). If `active_patches` ever empties, the official `app.asar`
  ships byte-identical with no extract/repack at all (lines 66–71).
- **`scripts/setup/official-deb.sh`**, `scripts/launcher-common.sh`, and
  `scripts/doctor.sh` contain no node-pty handling — nothing is needed; the
  official tree arrives with its own prebuilt binary. The parked
  `scripts/cowork-fallback/README.md` confirms "Nothing here is executed,
  installed, or patched into any artifact."

The verdict is unconditional in the matrix (plain **delete**, not "survivor
candidate" or "verify behaviorally"), and the doc's Open items list contains
no node-pty entry.

## Gaps

- **No motivating issue for PR #152 was found.** The origin reads as a
  self-initiated feature (PR body cites the macOS optional dep as precedent);
  "self-motivated" is my inference, not a documented fact.
- **Exact upstream Claude Desktop version at origin is unrecorded** — the
  2026-01-05 `build.sh` fetched an unversioned installer URL and derived the
  version at build time from the nupkg name.
- **Runtime confirmation that the official build's Code-tab terminal works on
  Linux was not found.** The delete verdict rests on byte presence of the
  prebuilt ELF (matrix row + audit tool), not a live shell-spawn test, and
  the verification doc's Open items don't list one. In particular, whether
  the official bundle moots #728 (powershell.exe hardcode) and ships whatever
  spawn-helper equivalent #727 identified inside its `prebuilds/` layout was
  not verified in anything I read. This does not condition the *delete* (the
  legacy provisioning is redundant either way); it conditions whether
  #727/#728 can be closed as fixed-by-v3.0.0.
- **No recorded disposition for open PR #761** (targets `nix/node-pty.nix`
  and `scripts/patches/cowork.sh`/`claude-code.sh`, all deleted or parked by
  d9cef9e). Presumably superseded by the rebase, but that is inference — no
  comment or plan entry I found says so.
- Whether commits 3db7866/de604e9 (authored 2026-05-09, merged 2026-05-14 and
  2026-05-24 via PRs #598/#597) were cherry-picked or rebased at merge is
  unexamined (author vs committer dates differ for de604e9); immaterial to
  the unit's story.
