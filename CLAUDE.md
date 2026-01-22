# Claude Desktop Debian - Development Notes

## Project Overview

This project repackages Claude Desktop (Electron app) for Debian/Ubuntu Linux, applying necessary patches for Linux compatibility.

## GitHub Workflow

### General Approach

- Use `gh` CLI for all GitHub interactions
- Create branches based on issue numbers: `fix/123-description` or `feature/123-description`
- Reference issues in commits and PRs with `#123` or `Fixes #123`
- After creating a PR, add a comment to the related issue with a summary and link to the PR

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

## Working with Minified JavaScript

### Important Guidelines

1. **Always use regex patterns** when modifying the source JavaScript in `build.sh`. Variable and function names are minified and **change between releases**.

2. **The beautified code in `build-reference/` has different spacing** than the actual minified code in the app. Patterns must handle both:
   - Minified: `oe.nativeTheme.on("updated",()=>{`
   - Beautified: `oe.nativeTheme.on("updated", () => {`

3. **Use `-E` flag with sed** for extended regex support when patterns need grouping or alternation.

4. **Extract variable names dynamically** rather than hardcoding them. Example from `build.sh`:
   ```bash
   # Extract function name from a known pattern
   TRAY_FUNC=$(grep -oP 'on\("menuBarEnabled",\(\)=>\{\K\w+(?=\(\)\})' app.asar.contents/.vite/build/index.js)
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

## Frame Fix Wrapper

The app uses a wrapper system to intercept and fix Electron behavior for Linux:

- **`frame-fix-wrapper.js`** - Intercepts `require('electron')` to patch BrowserWindow defaults (e.g., `frame: true` for proper window decorations on Linux)
- **`frame-fix-entry.js`** - Entry point that loads the wrapper before the main app

These are injected by `build.sh` and referenced in `package.json`'s `main` field. The wrapper pattern allows fixing Electron behavior without modifying the minified app code directly.

## Setting Up build-reference

If `build-reference/` is missing or you need to inspect source for a new version, follow these steps to download, extract, and beautify the source code.

### Prerequisites

```bash
# Install required tools
sudo apt install p7zip-full wget nodejs npm

# Install asar and prettier globally (or use npx)
npm install -g @electron/asar prettier
```

### Step 1: Download the Windows Installer

The Windows installer contains the app.asar which has the full Electron app source.

```bash
# Create working directory
mkdir -p build-reference && cd build-reference

# Download URL pattern (update version as needed):
# x64: https://downloads.claude.ai/releases/win32/x64/VERSION/Claude-COMMIT.exe
# arm64: https://downloads.claude.ai/releases/win32/arm64/VERSION/Claude-COMMIT.exe

# Example for version 1.1.381:
wget -O Claude-Setup-x64.exe "https://downloads.claude.ai/releases/win32/x64/1.1.381/Claude-c2a39e9c82f5a4d51f511f53f532afd276312731.exe"
```

### Step 2: Extract the Installer

```bash
# Extract the exe (it's a 7z archive)
7z x -y Claude-Setup-x64.exe -o"exe-contents"

# Find and extract the nupkg
cd exe-contents
NUPKG=$(find . -name "AnthropicClaude-*.nupkg" | head -1)
7z x -y "$NUPKG" -o"nupkg-contents"
cd ..

# Copy out the important files
cp exe-contents/nupkg-contents/lib/net45/resources/app.asar .
cp -a exe-contents/nupkg-contents/lib/net45/resources/app.asar.unpacked .

# Optional: copy tray icons for reference
mkdir -p tray-icons
cp exe-contents/nupkg-contents/lib/net45/resources/*.png tray-icons/ 2>/dev/null || true
cp exe-contents/nupkg-contents/lib/net45/resources/*.ico tray-icons/ 2>/dev/null || true
```

### Step 3: Extract app.asar

```bash
# Extract the asar archive
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
# Remove intermediate files, keep only what's needed for reference
rm -rf exe-contents
rm Claude-Setup-x64.exe
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
│   │   └── @ant/claude-native/   # Native bindings (stubs)
│   └── package.json
├── tray-icons/
│   ├── TrayIconTemplate.png      # Black icon (for light panels)
│   ├── TrayIconTemplate-Dark.png # White icon (for dark panels)
│   └── ...
└── nupkg-contents/               # Optional: full extracted nupkg
```

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

- `claude-desktop-VERSION-amd64.deb` - Debian package for x86_64
- `claude-desktop-VERSION-amd64.AppImage` - AppImage for x86_64
- `claude-desktop-VERSION-arm64.deb` - Debian package for ARM64
- `claude-desktop-VERSION-arm64.AppImage` - AppImage for ARM64

## Testing

### Local Build

```bash
./build.sh --build appimage --clean no
```

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

# Extract the running app's asar for inspection
npx asar extract /tmp/.mount_claudeXXXXXX/usr/lib/node_modules/electron/dist/resources/app.asar /tmp/claude-inspect

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

## Common Gotchas

- **`.zsync` files** - Used for delta updates, can be ignored/deleted
- **AppImage mount points** - Running AppImages mount to `/tmp/.mount_claude*`; check with `mount | grep claude`
- **Killing the app** - Must kill all electron child processes, not just the main one:
  ```bash
  pkill -9 -f "mount_claude"
  ```
- **SingletonLock** - If app won't start, check for stale lock: `~/.config/Claude/SingletonLock`
- **Node version** - Build requires Node.js; the script downloads its own if needed
