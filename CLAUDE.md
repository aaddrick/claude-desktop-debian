# Claude Desktop Debian - Development Notes

<!--
  This file is read by Claude Code. The content below is duplicated in
  AGENTS.md (read by other AI tools per the agents.md standard) so that
  contributors using either receive the same instructions without needing
  to cross-reference. Keep CLAUDE.md and AGENTS.md byte-identical below
  the H1 title (the sync-policy comment above is the one place they
  intentionally differ) — if you edit one, edit the other.
-->

## Required reading

These documents are the source of truth. If anything in this file conflicts with them, they win. Read them before opening a non-trivial issue or PR.

- [`CONTRIBUTING.md`](CONTRIBUTING.md) — what we accept, what goes upstream, subsystem owners, AI-attribution policy.
- [`docs/styleguides/bash_styleguide.md`](docs/styleguides/bash_styleguide.md) — shell-script conventions (forked from YSAP). Tabs, 80 cols, `[[ ]]`, no `set -e`, no `eval`.
- [`docs/styleguides/docs_styleguide.md`](docs/styleguides/docs_styleguide.md) — page anatomy, naming, antipatterns for the `docs/` tree.
- [`docs/index.md`](docs/index.md) — entry point for the rest of the repo docs.
- [`SECURITY.md`](SECURITY.md) — vulnerability reporting; what's in scope vs. upstream.

This file is a fast reference for the highest-leverage rules and the project's accumulated archaeology. New policy goes in the style guides or CONTRIBUTING.md.

## Project Overview

This project repackages **Anthropic's official Claude Desktop for Linux `.deb`** into the formats Anthropic doesn't serve (RPM, AppImage, Nix, AUR) plus our own `.deb`, and wraps every format in a launcher with Linux-environment fixes (Wayland opt-in, GPU-crash recovery, `--doctor` diagnostics). Since the v3.0.0 rebase (decision [D-002](docs/decisions.md)) the contract is **patch-zero**: the official `app.asar` ships byte-identical unless a patch justifies itself against official bytes as compensating a genuine Linux gap.

## Learnings

The [`docs/learnings/`](docs/learnings/) directory contains hard-won technical knowledge from debugging and fixing issues — things that aren't obvious from reading the code or docs alone. Consult these before working on related areas. Add new entries when you discover something non-obvious that would save future contributors (human or AI) significant time. Docs whose subject no longer ships live in [`docs/archive/`](docs/archive/) with an obsolescence header — they stay findable as diagnosis records.

- [`official-deb-rebase-verification.md`](docs/learnings/official-deb-rebase-verification.md) — patch-necessity matrix verified against Anthropic's official Linux `.deb` (which legacy patches the v3.0.0 rebase deletes, the two survivor candidates, and why), plus the install-layout facts the rebase depends on: `process.resourcesPath` helper resolution (relocation-safe), the hardcoded OVMF/AAVMF firmware probe list (not distro-safe), per-arch dependency contracts, SUID recording in `data.tar.xz`, and the official postinst's AppArmor + apt self-registration behavior; its "Open items" section is the live pre-ship checklist
- [`patching-minified-js.md`](docs/learnings/patching-minified-js.md) — general lessons from maintaining a long-lived patch suite against an actively re-minified upstream: anchor selection (literals over identifiers), the `\w` vs `$` identifier-capture trap, beautified false-negatives, idempotency guards, multi-site coordination, non-unique anchor disambiguation, and the SHA-256-pinned hypothesis-verification recipe — still load-bearing for the two survivor patches
- [`cross-build-host-vs-target.md`](docs/learnings/cross-build-host-vs-target.md) — the host-vs-target conflation class caught twice in the CI cutover: tools that run during the build key on `uname -m`, artifacts key on `--arch`; symptom is `Exec format error` on cross legs
- [`packaging-permissions.md`](docs/learnings/packaging-permissions.md) — restrictive-umask permission traps across deb/rpm/AppImage: `app.asar.unpacked` traversability, `dpkg-deb --root-owner-group`, the rpm `%defattr` file-mode trap
- [`nix.md`](docs/learnings/nix.md) — the official-deb Nix derivation: design contract, the live SRI auto-bump sed anchors, the sandbox SUID extraction trap, why the old Electron resource-path hack must not return, and testing without NixOS
- [`apt-worker-architecture.md`](docs/learnings/apt-worker-architecture.md) — APT/DNF binary distribution via Cloudflare Worker + GitHub Releases, redirect chain, credential ownership, heartbeat runbook
- [`wayland-global-shortcuts-portal.md`](docs/learnings/wayland-global-shortcuts-portal.md) — why Quick Entry's hotkey is focus-bound on GNOME Wayland (mutter dropped XWayland global key grabs), the native-Wayland + `GlobalShortcutsPortal` launcher change (opt-in via `CLAUDE_USE_WAYLAND=1`; fixes GNOME ≤49, default GNOME stays on XWayland), the "only the last `--enable-features` switch wins → merge into one flag" trap, the tri-state `CLAUDE_USE_WAYLAND` escape hatch, and the proof that GNOME 50 / xdg-desktop-portal ≥1.20 is still blocked upstream because Electron/Chromium never calls the host `Registry.Register` app-id handshake ([electron#51875](https://github.com/electron/electron/issues/51875)); wlroots (Niri/Sway/Hyprland) lack a portal GlobalShortcuts backend entirely
- [`mcp-double-spawn.md`](docs/learnings/mcp-double-spawn.md) — Stdio MCPs spawn 2× when chat and Code/Agent panels are both active, root cause in upstream session managers, MCP-author workaround; now first-party-reproducible → upstream report drafted
- [`plugin-install.md`](docs/learnings/plugin-install.md) — Anthropic & Partners plugin install flow, gate logic, backend endpoints, and DevTools recipes
- [`tray-rebuild-race.md`](docs/learnings/tray-rebuild-race.md) — the KDE Plasma SNI re-registration race and the in-place `setImage` + `setContextMenu` fast-path; validated — the official build converged on the same fix, our tray patch is deleted
- [`cowork-vm-daemon.md`](docs/learnings/cowork-vm-daemon.md) — the 2.x bwrap Cowork daemon lifecycle; superseded on KVM hosts by the official coworkd, kept as reference for the 3.1 fallback investigation
- [`test-harness-electron-hooks.md`](docs/learnings/test-harness-electron-hooks.md) — why constructor-level `BrowserWindow` wraps were silently bypassed by the (now-deleted) frame-fix Proxy, and the prototype-method hook pattern that remains correct for harness code
- [`test-harness-ax-tree-walker.md`](docs/learnings/test-harness-ax-tree-walker.md) — five non-obvious traps in the v7 fingerprint walker after the AX-tree migration: AX-enable async lag, navigateTo-to-same-URL no-op, claude.ai's flat `dialog>button[]` lists, the `more options for X` per-row shape, and sidebar virtualization vs the lookup-failure threshold

Archived (still useful as diagnosis records): [`docs/archive/linux-topbar-shim.md`](docs/archive/linux-topbar-shim.md) — the four topbar gates and the WCO/implicit-drag-region investigation (shim deleted; official builds render the topbar on Linux, and Bugs A/B/C moved to [`docs/upstream-reports/`](docs/upstream-reports/)); [`docs/archive/cowork-linux-handover.md`](docs/archive/cowork-linux-handover.md) — the 2.x patch-based Cowork stack handover.

## Code Style

All shell scripts in this project must follow the [Bash Style Guide](docs/styleguides/bash_styleguide.md). Key points:

- Tabs for indentation, lines under 80 characters (exception: URLs and regex patterns)
- Use `[[ ]]` for conditionals, `$(...)` for command substitution
- Single quotes for literals, double quotes for expansions
- Lowercase variables; UPPERCASE only for constants/exports
- Use `local` in functions, avoid `set -e` and `eval`

### Anti-patterns

- **Don't `set -e`.** It interacts badly with `$(...)` capture and function return values, and the project has historically debugged enough silent exits to settle the question. Check status explicitly: `cmd || handle_err`.
- **Don't `eval`.** Use arrays for argv composition (`cmd "${args[@]}"`). `eval` defeats every parser and is a permanent SC2046 magnet.
- **Don't use POSIX `[ ... ]`.** Always `[[ ... ]]`. POSIX `[` mis-parses unquoted expansions in ways `[[` does not.
- **Don't backtick.** Always `$(...)`. Backticks don't nest cleanly and conflict with markdown when patches are pasted into PR comments.
- **Don't hardcode the work directory.** Scripts that operate during a build use `$work_dir` (set by `build.sh`). A hardcoded path silently breaks the AppImage build, which runs in a different layout from the deb/rpm builds.
- **Don't wrap commands in `if cmd; then true; else false; fi`-style scaffolding.** Just `cmd` — the exit code is already there.
- **Don't append to a baseline file to silence `shellcheck`.** Fix the underlying issue. If a warning is genuinely a false positive, use a per-line `# shellcheck disable=SCXXXX` with a comment explaining why.

### Linting

Shell scripts are checked with `shellcheck` and GitHub Actions workflows with `actionlint` before pushing. When lint issues are found:

1. **Fix the code** - Correct the underlying issue rather than suppressing the warning
2. **Disable directives are a last resort** - Only use `# shellcheck disable=SCXXXX` when:
   - The warning is a false positive
   - The pattern is intentional and unavoidable
   - Always add a comment explaining why the disable is needed
3. **Run `/lint` to check manually** - Use this skill to check for issues before pushing

## Docs

- **One declarative sentence then a code block or list at the top of every page.** No "In this guide we will explore…" preamble. See [`docs/styleguides/docs_styleguide.md`](docs/styleguides/docs_styleguide.md).
- **Lowercase kebab-case filenames** for everything in `docs/`. Order belongs in [`docs/index.md`](docs/index.md), not filenames or numeric prefixes.
- **Real domain nouns over `foo`/`bar`** in walkthroughs. The project vocabulary is `patches`, `the launcher`, `the worker`, `app.asar`, `the minified bundle`, `the asar archive`, `the doctor surface`.
- **Subsystem deep-dives go under [`docs/learnings/`](docs/learnings/).** Surfacing knowledge there beats burying it in commit messages or in patch-script comments. Add an entry when you discover something non-obvious that would save the next contributor significant time.
- **Decisions go in [`docs/decisions.md`](docs/decisions.md) (ADR format).** Don't relitigate a settled direction inside a how-to page; link the decision instead.
- **Troubleshooting headings are the literal symptom**, not editorialized prose. `## Black screen on Fedora KDE under Wayland`, not `## Troubles with Wayland`. Search ranks headings.
- **CHANGELOG follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).** Bullets grouped under Added / Fixed / Changed / Deprecated / Removed / Security; one bullet per change; PR link for the deep dive; inline **BREAKING** prefix for breaking changes. See [`CHANGELOG.md`](CHANGELOG.md) for the current state and [`RELEASING.md`](RELEASING.md) for when entries get promoted from `[Unreleased]`.

## GitHub Workflow

### General Approach

- Use `gh` CLI for all GitHub interactions
- Create branches based on issue numbers: `fix/123-description` or `feature/123-description`
- Reference issues in commits and PRs with `#123` or `Fixes #123`
- After creating a PR, add a comment to the related issue with a summary and link to the PR

### Investigating Issues

For older issues, review the state of the code when the issue was raised - it may have already been addressed:

```bash
# Get issue creation date
gh issue view 123 --json createdAt

# Find the commit just before the issue was created
git log --oneline --until="2025-08-23T08:48:35Z" -1

# View a file at that point in time
git show <commit>:path/to/file.sh

# Search for relevant changes since the issue was created
git log --oneline --after="2025-08-23" -- path/to/file.sh

# View a specific commit that may have fixed the issue
git show <commit>
```

This helps identify if the issue was already fixed, and allows referencing the specific commit in the response.

### Attribution

**For PR descriptions**, include full attribution:

```
---
Generated with [Claude Code](https://claude.ai/code)
Co-Authored-By: Claude <model-name> <noreply@anthropic.com>
<XX>% AI / <YY>% Human
Claude: <what AI did>
Human: <what human did>
```

- Use the actual model name (e.g., `Claude Opus 4.5`, `Claude Sonnet 4`)
- The percentage split should honestly reflect the contribution balance for that specific work
- This provides a trackable record of AI-assisted development over time

**For issues and comments**, use simplified attribution:

```
---
Written by Claude <model-name> via [Claude Code](https://claude.ai/code)
```

**For commits**, include a Co-Authored-By trailer:

```
Co-Authored-By: Claude <claude@anthropic.com>
```

### Contributor Credits

[`ACKNOWLEDGMENTS.md`](ACKNOWLEDGMENTS.md) credits external contributors in chronological order (by merge date or fix date); the README Acknowledgments section keeps only the three inspirational projects and links there. Update `ACKNOWLEDGMENTS.md` when:

1. **Merging an external PR** — Add the author to the list with a link to their GitHub profile and a brief description of their contribution.
2. **Implementing a fix suggested in an issue** — If an issue author (or commenter) provided a concrete fix, workaround, code snippet, or detailed technical analysis that was directly used, credit them too.

Contributors are listed in chronological order: inspirational projects first (k3d3, emsi, leobuskin), then contributors ordered by when their contribution was merged or implemented.

## Working with Minified JavaScript

### Important Guidelines

1. **Always use regex patterns** when modifying the source JavaScript. Patches live in `scripts/patches/*.sh` — `app-asar.sh` is the orchestrator with the explicit `active_patches` array (currently `quick-window.sh` and `org-plugins.sh`; `config.sh` is kept unwired). An empty array ships the official `app.asar` byte-identical (patch-zero). Variable and function names are minified and **change between releases**; full anchor-craft lessons are in [`docs/learnings/patching-minified-js.md`](docs/learnings/patching-minified-js.md).

2. **The beautified code in `build-reference/` has different spacing** than the actual minified code in the app. Patterns must handle both:
   - Minified: `oe.nativeTheme.on("updated",()=>{`
   - Beautified: `oe.nativeTheme.on("updated", () => {`

3. **Use `-E` flag with sed** for extended regex support when patterns need grouping or alternation.

4. **Extract variable names dynamically** rather than hardcoding them. Example (from `scripts/patches/quick-window.sh`):
   ```bash
   # The minified Quick Entry window var, anchored on a stable literal
   quick_var=$(grep -oP '[$\w]+(?=\.setAlwaysOnTop\(\s*!0\s*,\s*"pop-up-menu"\))' \
       app.asar.contents/.vite/build/index.js)
   ```

5. **Handle optional whitespace** in regex patterns:
   ```bash
   # Bad: assumes no spaces
   sed -i 's/oe.nativeTheme.on("updated",()=>{/...'

   # Good: handles optional whitespace
   sed -i -E 's/(oe\.nativeTheme\.on\(\s*"updated"\s*,\s*\(\)\s*=>\s*\{)/...'
   ```

### Reference Files

- `build-reference/app-extracted/` - Extracted and beautified source for analysis
- `build-reference/tray-icons/` - Tray icon assets for reference

## Patch Orchestration (patch-zero)

`scripts/patches/app-asar.sh` owns the asar patch stage:

- **`active_patches` array** — the only place a patch gets wired in. Empty array ⇒ no extract, no repack, official `app.asar` ships byte-identical.
- **productName guard** — the build fails if upstream's `productName` stops matching `WM_CLASS` (breaks `StartupWMClass` in every `.desktop` file).
- **Upstream tripwires (AU-1/MB-1)** — the build fails if the official bundle stops shipping `apt_channel_pending` (autoupdater still pending, see [D-001](docs/decisions.md)) or `menuBarEnabled:!0` (menu-bar default). These replace the per-patch WARNINGs that left with the v3.0.0 deletions.
- **Repack invariant** — the unpacked-file set is derived from the shipped `app.asar.unpacked` tree and must match after repack, so upstream native helpers can't silently inline.

The 2.x frame-fix wrapper (`frame-fix-wrapper.js` `require('electron')` interception) is **gone** — the official build owns its window behavior. Any proposal to intercept Electron APIs again must clear the patch-zero bar in [D-002](docs/decisions.md).

## Setting Up build-reference

If `build-reference/` is missing or you need to inspect source for a new version, extract and beautify the bundle from the **official Linux `.deb`** (the Windows-installer recipe died with the v3.0.0 rebase).

### Prerequisites

```bash
# Install required tools (ar comes from binutils)
sudo apt install binutils wget xz-utils zstd nodejs npm

# Install asar and prettier globally (or use npx)
npm install -g @electron/asar prettier
```

### Step 1: Download the official .deb

The pinned version, pool path, and SHA-256 live in `scripts/setup/official-deb.sh` (`OFFICIAL_DEB_*`). To fetch the pinned amd64 build:

```bash
mkdir -p build-reference && cd build-reference

# Read the current pin
source ../scripts/setup/official-deb.sh 2>/dev/null || true
wget -O claude-desktop.deb \
  "https://downloads.claude.ai/claude-desktop/apt/stable/$OFFICIAL_DEB_POOL_AMD64"
echo "$OFFICIAL_DEB_SHA256_AMD64  claude-desktop.deb" | sha256sum -c
```

To inspect the newest pool entry instead, resolve it from the Packages index (`resolve_official_deb` in `official-deb.sh` does the same thing):

```bash
curl -fsS "https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-amd64/Packages" \
  | awk -v RS='' '/claude-desktop/' | grep -E '^(Version|Filename|SHA256):'
```

### Step 2: Extract the .deb

No dpkg required — `ar` + `tar` handle every member (the data member has shipped as both `.tar.zst` and `.tar.xz`; check with `ar t`):

```bash
ar t claude-desktop.deb                     # list members
ar p claude-desktop.deb data.tar.xz | tar -J -x   # or --zstd for .tar.zst

# The app tree lands at usr/lib/claude-desktop/
cp usr/lib/claude-desktop/resources/app.asar .
cp -a usr/lib/claude-desktop/resources/app.asar.unpacked .

# Optional: hicolor icons for reference
cp -a usr/share/icons/hicolor tray-icons
```

### Step 3: Extract app.asar

```bash
asar extract app.asar app-extracted
```

### Step 4: Beautify the JavaScript Files

The extracted JS files are minified. Use prettier to make them readable:

```bash
# Beautify all JS files in the build directory
npx prettier --write "app-extracted/.vite/build/*.js"

# Or beautify specific files
npx prettier --write app-extracted/.vite/build/index.js
npx prettier --write app-extracted/.vite/build/mainWindow.js
```

### Step 5: Clean Up (Optional)

```bash
# Keep only what's needed for reference
rm -rf usr claude-desktop.deb
rm -rf app.asar app.asar.unpacked  # Keep only app-extracted
```

### Final Structure

```
build-reference/
├── app-extracted/
│   ├── .vite/
│   │   ├── build/
│   │   │   ├── index.js          # Main process (beautified)
│   │   │   ├── mainWindow.js     # Main window preload
│   │   │   ├── mainView.js       # Main view preload
│   │   │   └── ...
│   │   └── renderer/
│   │       └── ...
│   ├── node_modules/
│   │   └── @ant/claude-native/   # Rust native binding (real on Linux)
│   └── package.json
└── tray-icons/                   # Official hicolor icons (optional)
```

Remember that patterns verified against beautified output need the whitespace-tolerant form when applied to the shipped minified bytes (see the guidelines above).

## Adding New Package Formats or Repositories

When adding support for new distribution formats (e.g., RPM, Flatpak, Snap) or package repositories, follow these guidelines to avoid iterative debugging in CI.

### Research Before Implementing

1. **Understand the target system's constraints** - Each package format has specific rules:
   - Version string formats (e.g., RPM cannot have hyphens in Version field)
   - Required metadata fields
   - Signing requirements and tools

2. **Search for existing CI implementations** - Look for "GitHub Actions [format] signing" or similar. Existing workflows reveal required flags, environment setup, and common pitfalls.

3. **Check tool behavior in non-interactive environments** - CI has no TTY. Tools like GPG need flags like `--batch` and `--yes` to work without prompts.

### Consider Concurrency

1. **Multiple jobs writing to the same branch will race** - If APT and DNF repos both push to `gh-pages`, add:
   - Job dependencies (`needs: [other-job]`), or
   - Retry loops with `git pull --rebase` before push

2. **External processes may also modify branches** - GitHub Pages deployment runs automatically and can cause push conflicts.

### Test the Full Pipeline

1. **Test CI steps locally first** - Run the signing/packaging commands manually to catch errors before committing.

2. **Use a test tag for new infrastructure** - Create a non-release tag to validate the full CI pipeline before merging to main.

3. **Verify the end-user experience** - After CI succeeds, actually test the install commands from the README on a clean system.

### Common CI Pitfalls

| Issue | Solution |
|-------|----------|
| GPG "cannot open /dev/tty" | Add `--batch` flag |
| GPG "File exists" error | Add `--yes` flag to overwrite |
| Push rejected (ref changed) | Add `git pull --rebase` before push, with retry loop |
| Version format invalid | Research target format's version constraints upfront |
| Signing key not found | Ensure key is imported before signing step, check key ID output |

## CI/CD

### Triggering Builds

```bash
# Trigger CI on a branch
gh workflow run CI --ref branch-name

# Watch the run
gh run watch RUN_ID

# Download artifacts
gh run download RUN_ID -n artifact-name
```

### Build Artifacts

- `claude-desktop_VERSION_amd64.deb` / `claude-desktop_VERSION_arm64.deb` - Debian packages
- `claude-desktop-VERSION-1.x86_64.rpm` / `claude-desktop-VERSION-1.aarch64.rpm` - RPM packages
- `claude-desktop-VERSION-amd64.AppImage` / `claude-desktop-VERSION-arm64.AppImage` - AppImages (+ `.zsync` in CI)
- `result/` - Nix build output (symlink, gitignored; the derivation is a stub until the @typedrat rework lands)

One cross-building `build.yml` produces all of these from `ubuntu-latest` via the `--arch` input (see [`docs/learnings/cross-build-host-vs-target.md`](docs/learnings/cross-build-host-vs-target.md) for the host-vs-target trap).

## Distribution

APT and DNF binaries are fronted by a Cloudflare Worker at `pkg.claude-desktop-debian.dev`. Metadata (`InRelease`, `Packages`, `KEY.gpg`, `repodata/*`) passes through to the `gh-pages` branch; binary requests (`/pool/.../*.deb`, `/rpm/*/*.rpm`) get 302'd to the corresponding GitHub Release asset. This keeps `.deb` / `.rpm` files out of `gh-pages` entirely, so they never hit GitHub's 100 MB per-file push cap.

Key files:
- `worker/src/worker.js` — Worker source
- `worker/wrangler.toml` — Worker config (route, `custom_domain = true`)
- `.github/workflows/deploy-worker.yml` — deploys on push to `main` when `worker/**` changes
- `.github/workflows/apt-repo-heartbeat.yml` — daily chain validation, auto-opens tracking issue on failure
- `update-apt-repo` and `update-dnf-repo` jobs in `.github/workflows/ci.yml` — gate a strip step on Worker liveness, so binaries are removed from the local pool tree before push

Repo secrets: `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`. Token scoped to the "Edit Cloudflare Workers" template.

Full details including the redirect chain, the http-scheme-downgrade gotcha, credential ownership, and heartbeat failure runbook: [`docs/learnings/apt-worker-architecture.md`](docs/learnings/apt-worker-architecture.md).

## Testing

### Local Build

```bash
./build.sh --build appimage --clean no
```

### Nix Build

```bash
nix build .#claude-desktop
nix build .#claude-desktop-fhs
```

The derivation repackages the official `.deb` (`fetchurl` + `autoPatchelfHook`, no nixpkgs Electron). Build-verified on x86_64 only — runtime on real NixOS and the aarch64 leg are open validation items (owner @typedrat; design contract and testing recipe in [`docs/learnings/nix.md`](docs/learnings/nix.md)).

### Testing AppImage

```bash
# Run with logging
./test-build/claude-desktop-*.AppImage 2>&1 | tee ~/.cache/claude-desktop-debian/launcher.log
```

## Debugging Workflow

### Inspecting the Running App's Code

```bash
# Find the mounted AppImage path
mount | grep claude
# Example: /tmp/.mount_claudeXXXXXX

# Extract the running app's asar for inspection (official bare
# co-located layout: ELF + chrome-sandbox + resources/ side by side)
npx asar extract /tmp/.mount_claudeXXXXXX/usr/lib/claude-desktop/resources/app.asar /tmp/claude-inspect

# Search for patterns in the extracted code
grep -n "pattern" /tmp/claude-inspect/.vite/build/index.js
```

### Checking DBus/Tray Status

```bash
# List registered tray icons
gdbus call --session --dest=org.kde.StatusNotifierWatcher \
  --object-path=/StatusNotifierWatcher \
  --method=org.freedesktop.DBus.Properties.Get \
  org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems

# Find which process owns a DBus connection
gdbus call --session --dest=org.freedesktop.DBus \
  --object-path=/org/freedesktop/DBus \
  --method=org.freedesktop.DBus.GetConnectionUnixProcessID ":1.XXXX"
```

### Log Locations

- Launcher log: `~/.cache/claude-desktop-debian/launcher.log`
- App logs: `~/.config/Claude/logs/`
- Run with logging: `./app.AppImage 2>&1 | tee ~/.cache/claude-desktop-debian/launcher.log`

## Useful Locations

- App data: `~/.config/Claude/`
- Logs: `~/.config/Claude/logs/`
- SingletonLock: `~/.config/Claude/SingletonLock`
- Launcher log: `~/.cache/claude-desktop-debian/launcher.log`

## Versioning

Release versions are managed via two GitHub Actions repository variables (not files):

- **`REPO_VERSION`** - The project's own version (e.g., `1.3.23`). Bump this manually via `gh variable set REPO_VERSION --body "X.Y.Z"` when shipping project changes.
- **`CLAUDE_DESKTOP_VERSION`** - The upstream Claude Desktop version (e.g., `1.1.8629`). Updated automatically by the `check-claude-version` workflow when a new upstream release is detected.

### Tag format

Tags follow the pattern `v{REPO_VERSION}+claude{CLAUDE_DESKTOP_VERSION}`, e.g., `v1.3.23+claude1.1.7714`. Pushing a tag triggers the CI release build.

```bash
# Check current values
gh variable get REPO_VERSION
gh variable get CLAUDE_DESKTOP_VERSION

# Bump repo version and tag a release
gh variable set REPO_VERSION --body "1.3.24"
git tag "v1.3.24+claude$(gh variable get CLAUDE_DESKTOP_VERSION)"
git push origin "v1.3.24+claude$(gh variable get CLAUDE_DESKTOP_VERSION)"
```

When upstream Claude Desktop updates, the `check-claude-version` workflow resolves the newest entry from the official APT `Packages` indexes (both arches, with a cross-arch agreement gate), seds the `OFFICIAL_DEB_*` pins in `scripts/setup/official-deb.sh` (and the Nix SRI hashes once the derivation stops being a stub), updates `CLAUDE_DESKTOP_VERSION`, and creates a new tag — no manual intervention needed. **Do not run it by hand from a branch**: the auto-tag cuts a release with whatever `REPO_VERSION` is staged.

## Common Gotchas

- **`.zsync` files** - Used for delta updates, can be ignored/deleted
- **AppImage mount points** - Running AppImages mount to `/tmp/.mount_claude*`; check with `mount | grep claude`
- **Killing the app** - Must kill all electron child processes, not just the main one:
  ```bash
  pkill -9 -f "mount_claude"
  ```
- **SingletonLock** - If app won't start, check for stale lock: `~/.config/Claude/SingletonLock`
- **Node version** - Build requires Node.js; the script downloads its own if needed (keyed to the HOST arch — see the cross-build learning)
- **Version pins** - The official `.deb` version, pool paths, and SHA-256 sums are pinned in `scripts/setup/official-deb.sh` (`OFFICIAL_DEB_*`), updated automatically by `check-claude-version` on main (which also seds the Nix SRI once the derivation lands). Before committing `scripts/setup/official-deb.sh`, ensure your branch carries the latest pins:
  ```bash
  # Check repo variable (source of truth)
  gh variable get CLAUDE_DESKTOP_VERSION

  # Check the pinned version on your branch
  grep -oP "^OFFICIAL_DEB_VERSION='\K[^']+" scripts/setup/official-deb.sh

  # What the official pool currently serves
  curl -fsS "https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-amd64/Packages" \
    | grep -E '^Version:' | sort -V | tail -1
  ```
- **data.tar compression varies** - Upstream has shipped both `data.tar.zst` and `data.tar.xz`; `_extract_deb_member` in `official-deb.sh` handles zst/xz/gz/plain, so never hardcode one
