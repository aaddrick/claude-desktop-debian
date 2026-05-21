# Security Policy

Report suspected vulnerabilities privately via [GitHub Security Advisories](https://github.com/aaddrick/claude-desktop-debian/security/advisories/new). Do not open a public issue or post details in Discussions.

## Scope

This project repackages an upstream Electron app. The boundary matters:

**In scope** — things this repo ships:

- Patches in `scripts/patches/*.sh`
- Packaging scripts in `scripts/packaging/`
- The launcher (`scripts/launcher-common.sh`) and the `claude-desktop --doctor` surface
- CI workflows under `.github/workflows/`
- The APT/DNF Cloudflare Worker under `worker/`
- The frame-fix wrapper and any other JS we inject into `app.asar`

**Out of scope** — file upstream:

- Vulnerabilities in the Claude Desktop application itself, the Anthropic API, or the claude.ai web app. Those go to Anthropic's support / disclosure channels — not here. This project can't fix them and shouldn't be the public record.

## What to include in a report

- Reproducer: commands, environment, distro / desktop / session type
- Output of `claude-desktop --doctor` if relevant
- Affected version(s) — `git describe --tags` or the release tag you installed from
- Any related upstream CVEs or advisories you found while investigating

## Response

GitHub Advisories notify @aaddrick. Acknowledgement is usually within a few days. Fix turnaround depends on the surface — packaging-layer bugs are usually fast; patches against minified upstream JS may need to wait for a tractable anchor in a future upstream release.

## Disclosure history

Past privacy-sensitive fixes (e.g., issue-triage bot scoping, log redaction in `--doctor` output) landed through the normal PR flow with public history; there have been no embargoed disclosures to date. If that changes, this section gets entries with the advisory ID, the affected versions, and the fix.
