---
name: extract-source
description: Download, extract, and beautify Claude Desktop source for analysis
---

Download, extract, and beautify Claude Desktop source code for analysis.

## Your Task

Set up the `build-reference/` directory with extracted and beautified source code.

### 1. Check Prerequisites

Check for required tools and offer to install missing ones:

```bash
# Required tools
tools_needed=()

command -v 7z &>/dev/null || tools_needed+=("p7zip-full")
command -v npx &>/dev/null || tools_needed+=("npm")
command -v wget &>/dev/null || tools_needed+=("wget")

# Check for asar (npm package)
npx asar --version &>/dev/null || tools_needed+=("@electron/asar (npm)")

# Check for prettier (npm package)
npx prettier --version &>/dev/null || tools_needed+=("prettier (npm)")
```

**If tools are missing**, ask the user if they want to install them:

- **System packages** (p7zip-full, npm, wget): `sudo apt install PACKAGE` or equivalent
- **NPM packages** (@electron/asar, prettier): `npm install -g @electron/asar prettier`

Do not proceed until all tools are available.

### 2. Get Version Info

```bash
# Get current version from build.sh
version=$(grep -oP 'x64/\K[0-9]+\.[0-9]+\.[0-9]+' build.sh | head -1)
echo "Extracting source for version: $version"
```

### 3. Download Windows Installer

```bash
mkdir -p build-reference && cd build-reference

# Get download URL from build.sh
download_url=$(grep -oP "claude_download_url='\\K[^']+(?=')" ../build.sh | head -1)

wget -O Claude-Setup-x64.exe "$download_url"
```

### 4. Extract the Installer

```bash
# Extract exe (it's a 7z archive)
7z x -y Claude-Setup-x64.exe -o"exe-contents"

# Find and extract nupkg
cd exe-contents
nupkg=$(find . -name "AnthropicClaude-*.nupkg" | head -1)
7z x -y "$nupkg" -o"nupkg-contents"
cd ..

# Copy out important files
cp exe-contents/nupkg-contents/lib/net45/resources/app.asar .
cp -a exe-contents/nupkg-contents/lib/net45/resources/app.asar.unpacked .

# Copy tray icons for reference
mkdir -p tray-icons
cp exe-contents/nupkg-contents/lib/net45/resources/*.png tray-icons/ 2>/dev/null || true
cp exe-contents/nupkg-contents/lib/net45/resources/*.ico tray-icons/ 2>/dev/null || true
```

### 5. Extract app.asar

```bash
npx asar extract app.asar app-extracted
```

### 6. Beautify JavaScript

```bash
# Beautify all JS files in build directory
npx prettier --write "app-extracted/.vite/build/*.js"
```

### 7. Clean Up

```bash
# Remove intermediate files
rm -rf exe-contents
rm Claude-Setup-x64.exe
rm -rf app.asar app.asar.unpacked
```

### 8. Report Results

Report the final structure:
```
build-reference/
├── app-extracted/     # Beautified source code
│   └── .vite/build/   # Main JS files (index.js, mainWindow.js, etc.)
└── tray-icons/        # Icon assets
```

Key files for analysis:
- `app-extracted/.vite/build/index.js` - Main process
- `app-extracted/.vite/build/mainWindow.js` - Window preload
- `app-extracted/package.json` - Package metadata

## Arguments

$ARGUMENTS
