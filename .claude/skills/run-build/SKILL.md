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

### 2. Determine Build Environment

Check the host distro:

```bash
if [[ -f /etc/debian_version ]]; then
	host_family='debian'
elif [[ -f /etc/redhat-release ]]; then
	host_family='rpm'
else
	host_family='unknown'
fi
echo "Host family: $host_family"
```

**Distrobox rules:**
- Building `.deb` or `.appimage`: use Debian distrobox (unless already on Debian)
- Building `.rpm`: use Fedora distrobox (unless already on RPM-based system)

The build script expects Debian tooling. Always use distrobox on non-Debian hosts.

### 3. Run Build

**On Debian host (direct build):**
```bash
./build.sh --build FORMAT --clean CLEAN
```

**On non-Debian host (use distrobox):**
```bash
# Create Debian container if it does not exist
if ! distrobox list | grep -q claude-build-debian; then
	distrobox create --name claude-build-debian --image ubuntu:24.04
fi

# Run build inside container
distrobox enter claude-build-debian -- \
	bash -c 'cd '"$(pwd)"' && ./build.sh --build FORMAT --clean CLEAN'
```

**For RPM builds on non-RPM host:**
```bash
# Create Fedora container if it does not exist
if ! distrobox list | grep -q claude-build-fedora; then
	distrobox create --name claude-build-fedora --image fedora:41
fi

# Run build inside container
distrobox enter claude-build-fedora -- \
	bash -c 'cd '"$(pwd)"' && ./build.sh --build rpm --clean CLEAN'
```

### 4. Report Results

After build completes:
1. Report the output file location
2. Note any warnings or errors
3. Suggest using `/test-build` to test the result

## Arguments

$ARGUMENTS
