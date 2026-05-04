# Contributing

## Where to find what

- [CLAUDE.md](CLAUDE.md): conventions, build, patches, attribution.
- [STYLEGUIDE.md](STYLEGUIDE.md): bash style ([style.ysap.sh](https://style.ysap.sh)).
  Tabs, 80 cols, `[[ ]]`, no `set -e`.
- [docs/learnings/](docs/learnings/): subsystem deep-dives. Read the
  relevant entry first.
- [docs/BUILDING.md](docs/BUILDING.md): local build setup.
- [docs/DECISIONS.md](docs/DECISIONS.md): architectural choices.
- [.github/CODEOWNERS](.github/CODEOWNERS): auto-review routing.

## What we accept

We're a repackager, not a fork. Net-new feature PRs default to no: we'd
own that behaviour across every re-minified upstream release.
Exception: parity patches for Windows features broken on Linux
(input methods, tray on Wayland/X11, frame defaults). Always welcome:

- Bug fixes against existing behaviour.
- Parity patches bringing Linux closer to the Windows build.
- Packaging, distribution, launcher fixes.
- Docs, tests, CI improvements.

## What goes upstream, not here

We patch the binary blob; we don't fix application logic inside it.
If the bug reproduces on Windows, file at
[anthropics/claude-code](https://github.com/anthropics/claude-code).
In-app `/bug` and `/feedback` are inert.

| File here                              | File upstream                       |
|----------------------------------------|-------------------------------------|
| `apt update` errors, install failures  | Plugin install fails on all OSes    |
| Tray icon missing on KDE Wayland       | Conversation rendering glitch       |
| AppImage won't launch on distro X      | MCP server connection drops         |
| `--doctor` reports wrong diagnosis     | Account / login flow broken         |

## Filing an issue

1. Use the issue template, not freeform.
2. Paste full `./build.sh --doctor` (or `claude-desktop --doctor`)
   output. Most-skipped step.
3. Include distro, DE, session type (Wayland/X11). Most Linux-only
   bugs trace to one of these.
4. Reproduce on a clean config: move `~/.config/Claude` aside, relaunch.
   Stale config causes false positives.

## Patches against upstream

Patches live in `scripts/patches/*.sh`, one per subsystem; `build.sh`
sources them. Before writing or editing one, read [the
patching-minified-js learnings doc][pmj]: anchor selection, capture,
idempotency, beautified-vs-minified gap. Short form: CLAUDE.md §
Working with Minified JavaScript.

Priority rule: a broken-patch upstream release beats feature work.

## Subsystem owners

CODEOWNERS auto-requests reviews; this list is for human discoverability.

- **@aaddrick**: default. Build, non-Cowork patches, desktop, packaging, docs.
- **@sabiut**: `tests/`, `scripts/doctor.sh`, test workflows.
- **@RayCharlizard**: Cowork (`scripts/patches/cowork.sh`,
  `scripts/cowork-vm-service.js`, `tests/cowork-*.bats`).
- **@typedrat**: Nix (`flake.nix`, `flake.lock`, `/nix/`).

## Before submitting a PR

- Run `/lint` (or `shellcheck` + `actionlint`). See CLAUDE.md § Linting.
- Local build: `./build.sh --build appimage --clean no`. Catches
  patch failures unit tests miss.
- Branch: `fix/123-description` or `feature/123-description`.
- PR body links the issue: `Fixes #123` or `Refs #123`.
- AI-assisted? Add the attribution block (next section).

## AI-assisted contributions

AI-assisted PRs accepted with disclosure. PR descriptions:

```
---
Generated with [Claude Code](https://claude.ai/code)
Co-Authored-By: Claude <model-name> <noreply@anthropic.com>
XX% AI / YY% Human
Claude: <what AI did>
Human: <what human did>
```

Real model name (e.g., "Claude Opus 4.7"). Honest split. 
Breakdown lines make the ratio auditable against the diff.

Commits: `Co-Authored-By: Claude <claude@anthropic.com>`. 

Issues/comments:
`Written by Claude <model-name> via [Claude Code](https://claude.ai/code)`.

## Conventions in this file

### Patch-script regexes

When a patch regex uses whitespace-tolerant constructs (`\s*`,
`[ \t]*`) between tokens, add an intent comment with whitespace stripped:

```js
// Intent: VAR.code==="ENOENT"
const enoentRe = /(\w+)\.code\s*===\s*"ENOENT"/g;
```

Apply to new patches and to existing regexes when editing for other
reasons. No churn PRs. Background: [the learnings doc][pmj].

[pmj]: docs/learnings/patching-minified-js.md

### Markdown prose wrapping

Wrap prose at ~80 chars, matching the bash column rule in
STYLEGUIDE.md. Tables, code blocks, URLs, alt text may exceed when
breaking hurts readability.
