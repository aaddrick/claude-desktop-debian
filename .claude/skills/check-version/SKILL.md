---
name: check-version
description: Check if a new Claude Desktop version is available
---

Check if a new Claude Desktop version is available.

## Your Task

Compare the current version in the repository against the latest available release.

### 1. Get Current Version

```bash
# From GitHub repo variable (source of truth)
gh variable get CLAUDE_DESKTOP_VERSION

# Check what's in build.sh
grep -oP 'x64/\K[0-9]+\.[0-9]+\.[0-9]+' build.sh | head -1
```

### 2. Check Latest Available Version

```bash
# Query the Windows update feed (same version as Linux)
curl -s 'https://downloads.claude.ai/releases/win32/x64/RELEASES' | head -5
```

### 3. Compare and Report

Report:
- **Current version**: from repo variable and build.sh
- **Latest version**: from update check
- **Status**: Up to date OR new version available

### 4. If Update Available

If a new version is detected:

1. Show the new download URLs:
   ```
   x64: https://downloads.claude.ai/releases/win32/x64/VERSION/Claude-COMMIT.exe
   arm64: https://downloads.claude.ai/releases/win32/arm64/VERSION/Claude-COMMIT.exe
   ```

2. Remind about the update process:
   - Update `CLAUDE_DESKTOP_VERSION` repo variable
   - Update URLs in `build.sh` (both amd64 and arm64)
   - Test the build with new version
   - Note: A GitHub Action automatically updates these on main when new versions are detected

## Arguments

$ARGUMENTS
