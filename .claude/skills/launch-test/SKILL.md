---
name: test-build
description: Launch and test the most recently built artifact with logging
---

Launch the most recently built Claude Desktop artifact for testing.

## Your Task

Find and run the most recent build output with appropriate logging.

### 1. Find Most Recent Build

Search for build artifacts in order of preference:

```bash
# Find most recent artifact by modification time
latest_appimage=$(ls -t *.AppImage 2>/dev/null | head -1)
latest_deb=$(ls -t *.deb 2>/dev/null | head -1)
latest_rpm=$(ls -t *.rpm 2>/dev/null | head -1)

# Also check test-build directory if it exists
[[ -d test-build ]] && latest_appimage=$(ls -t test-build/*.AppImage 2>/dev/null | head -1)
```

Report which artifact was found and its modification time.

### 2. Check if Distrobox is Needed

**AppImage**: Runs directly on any Linux system.

**DEB package**: Requires Debian/Ubuntu environment.
```bash
if [[ ! -f /etc/debian_version ]]; then
    echo "DEB package requires Debian/Ubuntu. Using distrobox..."
    # Install in distrobox and run
fi
```

**RPM package**: Requires RPM-based environment.

### 3. Launch with Logging

**For AppImage (most common):**
```bash
# Ensure log directory exists
mkdir -p ~/.cache/claude-desktop-debian

# Make executable and run with logging
chmod +x "$latest_appimage"
"$latest_appimage" 2>&1 | tee ~/.cache/claude-desktop-debian/launcher.log
```

**For installed packages:**
```bash
# Run the installed binary
claude-desktop 2>&1 | tee ~/.cache/claude-desktop-debian/launcher.log
```

### 4. Monitor Output

While running:
- Watch for startup errors
- Note any electron/node warnings
- Check for tray icon initialization messages

Log location: `~/.cache/claude-desktop-debian/launcher.log`

### 5. Cleanup Reminder

After testing, remind user:
- Kill processes: `pkill -9 -f "mount_claude"`
- Check for stale locks: `~/.config/Claude/SingletonLock`

## Arguments

$ARGUMENTS
