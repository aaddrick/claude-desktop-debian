---
name: build
description: Run local build with options (--build appimage --clean no)
---

Run a local build of Claude Desktop for Linux.

## Your Task

Build the project using `./build.sh` with appropriate options.

### 1. Determine Build Parameters

Ask the user if not specified in `$ARGUMENTS`:

- **Build format**: `deb`, `rpm`, or `appimage` (default: auto-detect based on distro)
- **Clean build**: `yes` or `no` (default: `no` for faster iteration)

### 2. Check if Distrobox is Needed

Distrobox is required when building a package format that does not match the host:

```bash
if [[ -f /etc/debian_version ]]; then
	host_family='debian'
elif [[ -f /etc/redhat-release ]]; then
	host_family='rpm'
else
	host_family='unknown'
fi
```

**Distrobox rules:**
- Building `.deb` on non-Debian host: use Debian/Ubuntu distrobox
- Building `.rpm` on non-RPM host: use Fedora distrobox
- Building `.appimage`: works on any host (no distrobox needed)

### 3. Run Build

**Direct build (no distrobox):**
```bash
./build.sh --build FORMAT --clean CLEAN
```

**With distrobox (if needed):**
```bash
# Create container if it does not exist
distrobox create --name claude-build-debian --image ubuntu:22.04 2>/dev/null || true

# Run build inside container
distrobox enter claude-build-debian -- \
	bash -c "cd $(pwd) && ./build.sh --build FORMAT --clean CLEAN"
```

### 4. Report Results

After build completes:
1. Report the output file location
2. Note any warnings or errors
3. Suggest using `/test-build` to test the result

## Arguments

$ARGUMENTS
