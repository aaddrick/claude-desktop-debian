# Documentation

Linux packaging, patching, and operations docs for the [Claude Desktop for Debian](../README.md) project. The README is the storefront; this is the manual.

```bash
# If you're here because something broke:
claude-desktop --doctor
# Then check troubleshooting.md below.
```

## Installation & building

- [**Building from source**](building.md) — `./build.sh`, format flags, the Electron mirror env vars
- [**Configuration**](configuration.md) — MCP config file locations, env vars, where state lives
- [**Troubleshooting**](troubleshooting.md) — symptom-keyed fixes, `--doctor` warning index

## Project direction

- [**Decision log**](decisions.md) — ADR-format record of what we ship and (more importantly) what we won't
- [**Releasing**](../RELEASING.md) — pre-release checklist, tag recipe, what CI does on tag push
- [**Changelog**](../CHANGELOG.md) — `v2.0.0` onward, grouped by REPO_VERSION

## How the patches work — subsystem deep-dives

Hard-won knowledge from debugging real bugs. Consult before working on the related subsystem; add a new entry when you discover something non-obvious that would save the next contributor (human or AI) significant time.

- [**Patching minified JavaScript**](learnings/patching-minified-js.md) — anchor selection, the `\w` vs `$` capture trap, beautified false-negatives, idempotency guards
- [**APT/DNF Worker architecture**](learnings/apt-worker-architecture.md) — Cloudflare Worker + GitHub Releases redirect chain, credential ownership, heartbeat runbook
- [**Nix packaging**](learnings/nix.md) — NixOS specifics, Electron resource path resolution, testing without NixOS
- [**Linux topbar shim**](learnings/linux-topbar-shim.md) — why the in-app topbar is missing on Linux and the four gates that hide it
- [**Tray rebuild race**](learnings/tray-rebuild-race.md) — KDE SNI re-registration race; the in-place `setImage`/`setContextMenu` fast path
- [**Plugin install flow**](learnings/plugin-install.md) — Anthropic & Partners plugin gate logic and DevTools recipes
- [**Cowork VM daemon**](learnings/cowork-vm-daemon.md) — lifecycle, respawn logic, crash diagnosis
- [**MCP double-spawn**](learnings/mcp-double-spawn.md) — why stdio MCPs spawn twice with chat + Code/Agent panels open
- [**Test harness — Electron hooks**](learnings/test-harness-electron-hooks.md) — why constructor-level `BrowserWindow` wraps get bypassed by the frame-fix Proxy
- [**Test harness — AX-tree walker**](learnings/test-harness-ax-tree-walker.md) — five non-obvious traps in the v7 fingerprint walker

## Testing

- [**Testing overview**](testing/README.md) — what we test and how it's organized
- [**Test runbook**](testing/runbook.md) — running tests locally
- [**Test matrix**](testing/matrix.md) — what runs on what distro / format
- [**Test automation**](testing/automation.md) — CI workflow shape
- [**Quick-entry closeout**](testing/quick-entry-closeout.md) — the Quick Entry test runner

## Operations

- [**Issue triage bot**](issue-triage/README.md) — how the GitHub Actions issue-triage workflow works
- [**Upstream bug reports**](upstream-reports/) — bugs we've filed against the upstream Electron app

## Style guides

- [**Bash style guide**](styleguides/bash_styleguide.md) — the project's shell-script conventions (forked from YSAP)
- [**Docs style guide**](styleguides/docs_styleguide.md) — how to write and organize docs (start here if you're adding a page)

## Contributing

- [**CONTRIBUTING.md**](../CONTRIBUTING.md) — what we accept, what goes upstream, AI-attribution policy
- [**CLAUDE.md**](../CLAUDE.md) — instructions for AI coding assistants (and a useful project archaeology read for humans)
- [**AGENTS.md**](../AGENTS.md) — vendor-neutral mirror of `CLAUDE.md` for non-Claude AI tools
- [**SECURITY.md**](../SECURITY.md) — private vulnerability reporting

## Cowork-Linux handover (historical)

- [**Cowork-Linux handover**](cowork-linux-handover.md) — record of the original cowork Linux work, kept for the historical context. Day-to-day cowork docs live in [`learnings/cowork-vm-daemon.md`](learnings/cowork-vm-daemon.md).
