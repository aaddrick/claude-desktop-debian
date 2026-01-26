---
name: setup-build-tools
description: Install build and extraction tools needed for building Claude Desktop Debian packages
---

Install the build dependencies required to run build.sh and create .deb/.AppImage packages.

## Your Task

Run the build tools installation script to ensure all required tools are available:

```bash
bash "$CLAUDE_PROJECT_DIR/.claude/hooks/install-build-tools.sh"
```

## Tools Installed

This script installs:

| Tool | Package | Purpose |
|------|---------|---------|
| `7z` | p7zip-full | Extract Windows installers and nupkg archives |
| `wget` | wget | Download Claude Desktop installers |
| `wrestool` | icoutils | Extract icons from Windows executables |
| `convert` | imagemagick | Process tray icons for Linux |
| `dpkg-deb` | dpkg-dev | Build .deb packages |
| `libfuse2` | libfuse2 | Run AppImages |
| `node` | nodejs | Node.js v20+ for npm/asar operations |

## When to Use

- Before running `./build.sh` for the first time
- After setting up a new development environment
- When build.sh fails due to missing dependencies

## Optional Guidance

$ARGUMENTS
