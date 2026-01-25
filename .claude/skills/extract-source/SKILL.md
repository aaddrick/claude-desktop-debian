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
tools_needed=()

command -v 7z &>/dev/null || tools_needed+=('p7zip-full')
command -v npx &>/dev/null || tools_needed+=('npm')
command -v wget &>/dev/null || tools_needed+=('wget')

npx asar --version &>/dev/null || tools_needed+=('@electron/asar (npm)')
npx prettier --version &>/dev/null || tools_needed+=('prettier (npm)')
```

If tools are missing, ask the user to install them:

- **System packages**: `sudo apt install p7zip-full npm wget`
- **NPM packages**: `npm install -g @electron/asar prettier`

Do not proceed until all tools are available.

### 2. Get Version and Set Paths

```bash
version=$(grep -oP 'x64/\K[0-9]+\.[0-9]+\.[0-9]+' build.sh | head -1)
ref_dir="$PWD/build-reference"
echo "Extracting source for version: $version"
echo "Output directory: $ref_dir"
```

**Important**: Save `$ref_dir` and use it in all subsequent commands. Do not use `cd`.

### 3. Download Windows Installer

```bash
mkdir -p "$ref_dir"
download_url=$(grep -oP "claude_download_url='\\K[^']+(?=')" build.sh | head -1)
wget -O "$ref_dir/Claude-Setup-x64.exe" "$download_url"
```

### 4. Extract the Installer

```bash
# Extract exe (it's a 7z archive)
7z x -y "$ref_dir/Claude-Setup-x64.exe" -o"$ref_dir/exe-contents"

# Find and extract nupkg
for nupkg in "$ref_dir"/exe-contents/AnthropicClaude-*.nupkg; do
	7z x -y "$nupkg" -o"$ref_dir/exe-contents/nupkg-contents"
	break
done

# Copy out important files
cp "$ref_dir"/exe-contents/nupkg-contents/lib/net45/resources/app.asar "$ref_dir/"
cp -a "$ref_dir"/exe-contents/nupkg-contents/lib/net45/resources/app.asar.unpacked "$ref_dir/"

# Copy tray icons for reference
mkdir -p "$ref_dir/tray-icons"
cp "$ref_dir"/exe-contents/nupkg-contents/lib/net45/resources/*.png "$ref_dir/tray-icons/" 2>/dev/null || true
cp "$ref_dir"/exe-contents/nupkg-contents/lib/net45/resources/*.ico "$ref_dir/tray-icons/" 2>/dev/null || true
```

### 5. Extract app.asar

```bash
npx asar extract "$ref_dir/app.asar" "$ref_dir/app-extracted"
```

### 6. Beautify JavaScript

```bash
npx prettier --write "$ref_dir/app-extracted/.vite/build/*.js"
```

### 7. Clean Up

```bash
rm -rf "$ref_dir/exe-contents" "$ref_dir/Claude-Setup-x64.exe" "$ref_dir/app.asar" "$ref_dir/app.asar.unpacked"
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
