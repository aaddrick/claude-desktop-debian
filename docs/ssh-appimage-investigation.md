# SSH Remote Development — AppImage Rendering Issue

## Summary

Issue #235 reported that SSH Remote Development fails on Linux because the
`claude-ssh` binaries are missing from the packages. The fix is straightforward
for deb/rpm (bundle the binaries extracted from the macOS DMG), but the AppImage
has an unresolved side-effect: including the real binaries in the squashfs
**breaks rendering** (fonts fail to load).

## What Was Implemented

`feature/235-claude-ssh` adds a `download_claude_ssh()` function to `build.sh`
that downloads the macOS universal DMG and extracts the Linux binaries from it:

- `resources/claude-ssh/claude-ssh-linux-amd64`
- `resources/claude-ssh/claude-ssh-linux-arm64`
- `resources/claude-ssh/version.txt`

Binary names and paths match exactly what the app expects (confirmed by
decompiling `app.asar`):

```javascript
// path.join(process.resourcesPath, "claude-ssh", "version.txt")
// path.join(process.resourcesPath, "claude-ssh", `claude-ssh-${platform}-${arch}`)
// arch is "amd64" or "arm64" (from remote uname -sm), NOT "x64"
```

The binaries are only read at SSH connection time, never at app startup.

## The Problem: AppImage Rendering Breaks

When the real binaries are included in the AppImage squashfs, the app renders
incorrectly — fonts fail to load, appearing as CSP-like errors in the console.

### Test Matrix

| Contents of `resources/claude-ssh/` | Renders? |
|--------------------------------------|----------|
| (empty / missing)                    | ✅ Yes   |
| `version.txt` only                   | ✅ Yes   |
| Tiny ELF stubs (64 bytes, non-exec)  | ✅ Yes   |
| Tiny ELF stubs (64 bytes, +x)        | ✅ Yes   |
| Real binaries (~50 MB each, +x)      | ❌ No    |

The rendering break is caused by **file size**, not ELF type or executable bit.

### Root Cause: VMA Exhaustion

An AppImage's squashfs is FUSE-mounted at startup. Every block of every large
file in the squashfs consumes virtual memory area (VMA) mappings in every
process. Chromium's renderer sandbox has hard limits on VMA count — Electron
already uses 20k–35k VMAs at startup. Adding ~100 MB of Go binaries to the
squashfs pushes the block-mapped VMAs high enough that the renderer runs out of
address space for certain operations (e.g. network buffers for font loading).

The renderer doesn't crash visibly — it silently fails to load certain resources,
which appears as font/CSP errors.

**This does not affect deb/rpm packages** because those files live on the real
filesystem, not a FUSE squashfs.

## Status

- **deb/rpm**: ✅ Ready — binaries on real filesystem, no rendering issue.
- **AppImage**: ❌ Blocked — binaries cannot live in the squashfs.

## Path Forward for AppImage

The binaries need to reach `process.resourcesPath/claude-ssh/` without being
packed into the squashfs. Options:

### Option A — Skip binaries in AppImage (simplest)

Only include `version.txt` in the AppImage squashfs. The SSH settings UI will
show but connections will fail with "Binary not found". Document that SSH Remote
Development requires the deb/rpm install.

### Option B — Lazy download on first SSH use (recommended)

1. Patch `Nbt()`/`Mbt()` (the path-construction functions in `app.asar`) via
   `sed` in `build.sh` to check `process.env.CLAUDE_SSH_PATH` first, falling
   back to `process.resourcesPath`.
2. In the AppImage launcher, set `CLAUDE_SSH_PATH=$HOME/.local/share/claude-desktop`.
3. On first SSH use (or at launcher startup), download the binaries from the
   GitHub release and store them at `$CLAUDE_SSH_PATH/claude-ssh/`.
4. In CI, upload `claude-ssh-linux-amd64` and `claude-ssh-linux-arm64` as
   release assets alongside the deb/AppImage artifacts.

This gives full SSH support in AppImage builds without squashfs bloat.

### Option C — Raise vm.max_map_count (fragile)

Set `vm.max_map_count` to a higher value before starting Electron. Requires
root. Not viable for a general-purpose AppImage.
