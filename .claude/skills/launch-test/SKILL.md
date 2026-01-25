---
name: test-build
description: Launch and test the most recently built artifact with logging
---

Launch the most recently built Claude Desktop artifact for testing.

## Your Task

Find and run the most recent build output with appropriate logging.

### 1. Find Most Recent Build

Search for build artifacts using glob patterns:

```bash
# Find artifacts by modification time (newest first)
# Check test-build directory first, then current directory
for appimage in test-build/*.AppImage *.AppImage; do
	[[ -f $appimage ]] && break
done

for deb in test-build/*.deb *.deb; do
	[[ -f $deb ]] && break
done

for rpm in test-build/*.rpm *.rpm; do
	[[ -f $rpm ]] && break
done
```

Report which artifact was found and its modification time.

### 2. Check if Distrobox is Needed

**AppImage**: Runs directly on any Linux system.

**DEB package**: Requires Debian/Ubuntu environment.
```bash
if [[ ! -f /etc/debian_version ]]; then
	echo 'DEB package requires Debian/Ubuntu. Using distrobox...'
fi
```

**RPM package**: Requires RPM-based environment.

### 3. Launch with Logging

**For AppImage (most common):**
```bash
mkdir -p ~/.cache/claude-desktop-debian
chmod +x "$appimage"
"$appimage" 2>&1 | tee ~/.cache/claude-desktop-debian/launcher.log
```

**For installed packages:**
```bash
claude-desktop 2>&1 | tee ~/.cache/claude-desktop-debian/launcher.log
```

### 4. Monitor Output

While running, watch for:
- Startup errors
- Electron/node warnings
- Tray icon initialization messages

Log location: `~/.cache/claude-desktop-debian/launcher.log`

### 5. Cleanup Reminder

After testing, remind user:
- Kill processes: `pkill -9 -f 'mount_claude'`
- Check for stale locks: `~/.config/Claude/SingletonLock`

## Arguments

$ARGUMENTS
