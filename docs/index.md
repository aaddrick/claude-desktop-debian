# Documentation

Linux packaging, patching, and operations docs for the [Claude Desktop for Debian](../README.md) project. The README is the storefront; this is the manual.

```bash
# If you're here because something broke:
claude-desktop --doctor
# Then check troubleshooting.md below.
```

## Installation & building

- [**Building from source**](building.md) — `./build.sh`, format flags, how the official `.deb` is pinned and extracted
- [**Configuration**](configuration.md) — MCP config file locations, env vars, where state lives
- [**Troubleshooting**](troubleshooting.md) — symptom-keyed fixes, `--doctor` warning index

## Project direction

- [**Decision log**](decisions.md) — ADR-format record of what we ship and (more importantly) what we won't
- [**Releasing**](../RELEASING.md) — pre-release checklist, tag recipe, what CI does on tag push
- [**Changelog**](../CHANGELOG.md) — `v2.0.0` onward, grouped by REPO_VERSION

## How the patches work — subsystem deep-dives

Hard-won knowledge from debugging real bugs. Consult before working on the related subsystem; add a new entry when you discover something non-obvious that would save the next contributor (human or AI) significant time.

- [**Official-deb rebase verification**](learnings/official-deb-rebase-verification.md) — patch-necessity matrix against the official Linux `.deb`, the install-layout facts the v3.0.0 rebase depends on, and the live pre-ship open-items checklist
- [**Patching minified JavaScript**](learnings/patching-minified-js.md) — anchor selection, the `\w` vs `$` capture trap, beautified false-negatives, idempotency guards; still load-bearing for the two survivor patches
- [**Cross-build: host vs target**](learnings/cross-build-host-vs-target.md) — tools that run during the build key on `uname -m`, artifacts key on `--arch`; the `Exec format error` class caught twice in the CI cutover
- [**Packaging permissions**](learnings/packaging-permissions.md) — restrictive-umask traps across deb/rpm/AppImage (`app.asar.unpacked` traversability, `--root-owner-group`, the rpm `%defattr` file-mode trap)
- [**APT/DNF Worker architecture**](learnings/apt-worker-architecture.md) — Cloudflare Worker + GitHub Releases redirect chain, credential ownership, heartbeat runbook
- [**Nix packaging**](learnings/nix.md) — the derivation stub and its official-tree rework design, why the resource-path hack must not return, testing without NixOS
- [**Wayland GlobalShortcuts portal**](learnings/wayland-global-shortcuts-portal.md) — why Quick Entry's hotkey is focus-bound on GNOME Wayland and the `CLAUDE_USE_WAYLAND` tri-state
- [**Tray rebuild race**](learnings/tray-rebuild-race.md) — KDE SNI re-registration race; validated — the official build converged on the same in-place fix
- [**Plugin install flow**](learnings/plugin-install.md) — Anthropic & Partners plugin gate logic and DevTools recipes
- [**Cowork VM daemon**](learnings/cowork-vm-daemon.md) — the 2.x bwrap daemon; superseded on KVM hosts, reference for the 3.1 fallback investigation
- [**MCP double-spawn**](learnings/mcp-double-spawn.md) — why stdio MCPs spawn twice with chat + Code/Agent panels open
- [**Test harness — Electron hooks**](learnings/test-harness-electron-hooks.md) — why constructor-level `BrowserWindow` wraps were bypassed by the (now-deleted) frame-fix Proxy; the prototype-hook pattern that remains correct
- [**Test harness — AX-tree walker**](learnings/test-harness-ax-tree-walker.md) — five non-obvious traps in the v7 fingerprint walker

## Testing

- [**Testing overview**](testing/README.md) — what we test and how it's organized
- [**Test runbook**](testing/runbook.md) — running tests locally
- [**Test matrix**](testing/matrix.md) — what runs on what distro / format
- [**Test automation**](testing/automation.md) — CI workflow shape
- [**Quick-entry closeout**](testing/quick-entry-closeout.md) — the Quick Entry test runner

## Operations

- [**Issue triage bot**](issue-triage/README.md) — how the GitHub Actions issue-triage workflow works
- [**Upstream bug reports**](upstream-reports/README.md) — the pending pile: drafts and filing status for bugs that belong upstream (Anthropic or Electron)

## Style guides

- [**Bash style guide**](styleguides/bash_styleguide.md) — the project's shell-script conventions (forked from YSAP)
- [**Docs style guide**](styleguides/docs_styleguide.md) — how to write and organize docs (start here if you're adding a page)

## Contributing

- [**CONTRIBUTING.md**](../CONTRIBUTING.md) — what we accept, what goes upstream, AI-attribution policy
- [**CLAUDE.md**](../CLAUDE.md) — instructions for AI coding assistants (and a useful project archaeology read for humans)
- [**AGENTS.md**](../AGENTS.md) — vendor-neutral mirror of `CLAUDE.md` for non-Claude AI tools
- [**SECURITY.md**](../SECURITY.md) — private vulnerability reporting

## Archive

Docs whose subject no longer ships, kept with an obsolescence header because the diagnosis work is still worth reading.

- [**Linux topbar shim**](archive/linux-topbar-shim.md) — the four topbar gates and the WCO/implicit-drag-region investigation; the shim was deleted in v3.0.0 (official builds render the topbar on Linux), and its three Electron bugs moved to [`upstream-reports/`](upstream-reports/README.md)
- [**Cowork-Linux handover**](archive/cowork-linux-handover.md) — record of the original patch-based cowork Linux work, superseded by the official KVM path; the bwrap daemon is parked under `scripts/cowork-fallback/`
