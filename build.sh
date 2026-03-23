#!/usr/bin/env bash

#===============================================================================
# Claude Desktop Debian Build Script
# Repackages Claude Desktop (Electron app) for Debian/Ubuntu Linux
#===============================================================================

# Global variables (set by functions, used throughout)
architecture=''
distro_family=''  # debian, rpm, nix, or unknown
claude_download_url=''
claude_exe_sha256=''
claude_exe_filename=''
version=''
release_tag=''  # Optional release tag (e.g., v1.3.2+claude1.1.799) for unique package versions
build_format=''  # Will be set based on distro if not specified
cleanup_action='yes'
perform_cleanup=false
test_flags_mode=false
local_exe_path=''
node_pty_dir=''
source_dir=''
original_user=''
original_home=''
project_root=''
work_dir=''
app_staging_dir=''
chosen_electron_module_path=''
electron_var=''
electron_var_re=''
asar_exec=''
claude_extract_dir=''
electron_resources_dest=''
node_pty_build_dir=''
final_output_path=''

# Package metadata (constants)
readonly PACKAGE_NAME='claude-desktop'
readonly MAINTAINER='Claude Desktop Linux Maintainers'
readonly DESCRIPTION='Claude Desktop for Linux'

#===============================================================================
# Utility Functions
#===============================================================================

check_command() {
	if ! command -v "$1" &> /dev/null; then
		echo "$1 not found"
		return 1
	else
		echo "$1 found"
		return 0
	fi
}

section_header() {
	echo -e "\033[1;36m--- $1 ---\033[0m"
}

section_footer() {
	echo -e "\033[1;36m--- End $1 ---\033[0m"
}

verify_sha256() {
	local file_path="$1"
	local expected_hash="$2"
	local label="${3:-file}"

	if [[ -z $expected_hash ]]; then
		echo "Warning: No SHA-256 hash for ${label}," \
			'skipping verification' >&2
		return 0
	fi

	echo "Verifying SHA-256 checksum for ${label}..."
	local actual_hash _
	read -r actual_hash _ < <(sha256sum "$file_path")

	if [[ $actual_hash != "$expected_hash" ]]; then
		echo "SHA-256 mismatch for ${label}!" >&2
		echo "  Expected: $expected_hash" >&2
		echo "  Actual:   $actual_hash" >&2
		return 1
	fi

	echo "SHA-256 verified: ${label}"
}

#===============================================================================
# Setup Functions
#===============================================================================

detect_architecture() {
	section_header 'Architecture Detection'
	echo 'Detecting system architecture...'

	local raw_arch
	raw_arch=$(uname -m) || {
		echo 'Failed to detect architecture' >&2
		exit 1
	}
	echo "Detected machine architecture: $raw_arch"

	case "$raw_arch" in
		x86_64)
			claude_download_url='https://downloads.claude.ai/releases/win32/x64/1.1.7714/Claude-3bd6f69326a0abac98bb269c29140e2a543cad64.exe'
			claude_exe_sha256=''
			architecture='amd64'
			claude_exe_filename='Claude-Setup-x64.exe'
			echo 'Configured for amd64 (x86_64) build.'
			;;
		aarch64)
			claude_download_url='https://downloads.claude.ai/releases/win32/arm64/1.1.7714/Claude-3bd6f69326a0abac98bb269c29140e2a543cad64.exe'
			claude_exe_sha256=''
			architecture='arm64'
			claude_exe_filename='Claude-Setup-arm64.exe'
			echo 'Configured for arm64 (aarch64) build.'
			;;
		*)
			echo "Unsupported architecture: $raw_arch. This script supports x86_64 (amd64) and aarch64 (arm64)." >&2
			exit 1
			;;
	esac

	echo "Target Architecture: $architecture"
	section_footer 'Architecture Detection'
}

detect_distro() {
	section_header 'Distribution Detection'
	echo 'Detecting Linux distribution family...'

	if [[ -f /etc/debian_version ]]; then
		distro_family='debian'
		echo "Detected Debian-based distribution"
		echo "  Debian version: $(cat /etc/debian_version)"
	elif [[ -f /etc/fedora-release ]]; then
		distro_family='rpm'
		echo "Detected Fedora"
		echo "  $(cat /etc/fedora-release)"
	elif [[ -f /etc/redhat-release ]]; then
		distro_family='rpm'
		echo "Detected Red Hat-based distribution"
		echo "  $(cat /etc/redhat-release)"
	elif [[ -f /etc/NIXOS ]]; then
		distro_family='nix'
		echo "Detected NixOS"
	else
		distro_family='unknown'
		echo "Warning: Could not detect distribution family"
		echo "  AppImage build will still work, but native packages (deb/rpm) may not"
	fi

	echo "Distribution: $(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'Unknown')"
	echo "Distribution family: $distro_family"
	section_footer 'Distribution Detection'
}

check_system_requirements() {
	# Allow running as root in CI/container environments
	if (( EUID == 0 )); then
		if [[ -n ${CI:-} || -n ${GITHUB_ACTIONS:-} || -f /.dockerenv ]]; then
			echo 'Running as root in CI/container environment (allowed)'
		else
			echo 'This script should not be run using sudo or as the root user.' >&2
			echo 'It will use sudo when needed for specific actions (may prompt for password).' >&2
			echo 'Please run as a normal user.' >&2
			exit 1
		fi
	fi

	original_user=$(whoami)
	original_home=$(getent passwd "$original_user" | cut -d: -f6)
	if [[ -z $original_home ]]; then
		echo "Could not determine home directory for user $original_user." >&2
		exit 1
	fi
	echo "Running as user: $original_user (Home: $original_home)"

	# Check for NVM and source it if found
	if [[ -d $original_home/.nvm ]]; then
		echo "Found NVM installation for user $original_user, checking for Node.js 20+..."
		export NVM_DIR="$original_home/.nvm"
		if [[ -s $NVM_DIR/nvm.sh ]]; then
			# shellcheck disable=SC1091
			\. "$NVM_DIR/nvm.sh"
			local node_bin_path=''
			node_bin_path=$(nvm which current | xargs dirname 2>/dev/null || \
				find "$NVM_DIR/versions/node" -maxdepth 2 -type d -name 'bin' | sort -V | tail -n 1)

			if [[ -n $node_bin_path && -d $node_bin_path ]]; then
				echo "Adding NVM Node bin path to PATH: $node_bin_path"
				export PATH="$node_bin_path:$PATH"
			else
				echo 'Warning: Could not determine NVM Node bin path.'
			fi
		else
			echo 'Warning: nvm.sh script not found or not sourceable.'
		fi
	fi

	echo 'System Information:'
	echo "Distribution: $(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'Unknown')"
	echo "Distribution family: $distro_family"
	echo "Target Architecture: $architecture"
}

parse_arguments() {
	section_header 'Argument Parsing'

	project_root="$(pwd)"
	work_dir="$project_root/build"
	app_staging_dir="$work_dir/electron-app"

	# Set default build format based on detected distro
	case "$distro_family" in
		debian) build_format='deb' ;;
		rpm) build_format='rpm' ;;
		nix) build_format='nix' ;;
		*) build_format='appimage' ;;
	esac

	while (( $# > 0 )); do
		case "$1" in
			-b|--build|-c|--clean|-e|--exe|-r|--release-tag|-s|--source-dir|--node-pty-dir)
				if [[ -z ${2:-} || $2 == -* ]]; then
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
				case "$1" in
					-b|--build) build_format="$2" ;;
					-c|--clean) cleanup_action="$2" ;;
					-e|--exe) local_exe_path="$2" ;;
					-r|--release-tag) release_tag="$2" ;;
					-s|--source-dir) source_dir="$2" ;;
					--node-pty-dir) node_pty_dir="$2" ;;
				esac
				shift 2
				;;
			--test-flags)
				test_flags_mode=true
				shift
				;;
			-h|--help)
				echo "Usage: $0 [--build deb|rpm|appimage|nix] [--clean yes|no] [--exe /path/to/installer.exe] [--source-dir /path] [--release-tag TAG] [--test-flags]"
				echo '  --build: Specify the build format (deb, rpm, appimage, or nix).'
				echo "           Default: auto-detected based on distro (current: $build_format)"
				echo '  --clean: Specify whether to clean intermediate build files (yes or no). Default: yes'
				echo '  --exe:   Use a local Claude installer exe instead of downloading'
				echo '  --source-dir: Path to repo root for scripts/ and assets (default: project root)'
				echo '  --node-pty-dir: Path to pre-built node-pty package (skips npm install)'
				echo '  --release-tag: Release tag (e.g., v1.3.2+claude1.1.799) to append wrapper version to package'
				echo '  --test-flags: Parse flags, print results, and exit without building.'
				exit 0
				;;
			*)
				echo "Unknown option: $1" >&2
				echo 'Use -h or --help for usage information.' >&2
				exit 1
				;;
		esac
	done

	# source_dir is where scripts/assets live (default: project_root)
	source_dir="${source_dir:-$project_root}"

	# Validate arguments
	build_format="${build_format,,}"
	cleanup_action="${cleanup_action,,}"

	if [[ ! -d $source_dir ]]; then
		echo "Error: --source-dir path does not exist: $source_dir" >&2
		exit 1
	fi
	if [[ -n $node_pty_dir && ! -d $node_pty_dir ]]; then
		echo "Error: --node-pty-dir path does not exist: $node_pty_dir" >&2
		exit 1
	fi

	if [[ $build_format != 'deb' && $build_format != 'rpm' && $build_format != 'appimage' && $build_format != 'nix' ]]; then
		echo "Invalid build format specified: '$build_format'. Must be 'deb', 'rpm', 'appimage', or 'nix'." >&2
		exit 1
	fi

	# Warn if building native package for wrong distro
	if [[ $build_format == 'deb' && $distro_family != 'debian' ]]; then
		echo "Warning: Building .deb package on non-Debian system ($distro_family). This may fail." >&2
	elif [[ $build_format == 'rpm' && $distro_family != 'rpm' ]]; then
		echo "Warning: Building .rpm package on non-RPM system ($distro_family). This may fail." >&2
	fi
	if [[ $cleanup_action != 'yes' && $cleanup_action != 'no' ]]; then
		echo "Invalid cleanup option specified: '$cleanup_action'. Must be 'yes' or 'no'." >&2
		exit 1
	fi

	echo "Selected build format: $build_format"
	echo "Cleanup intermediate files: $cleanup_action"

	[[ $cleanup_action == 'yes' ]] && perform_cleanup=true

	section_footer 'Argument Parsing'
}

check_dependencies() {
	echo 'Checking dependencies...'
	local deps_to_install=''
	local common_deps='p7zip wget wrestool icotool convert'
	local all_deps="$common_deps"

	# Add format-specific dependencies
	case "$build_format" in
		deb) all_deps="$all_deps dpkg-deb" ;;
		rpm) all_deps="$all_deps rpmbuild" ;;
	esac

	# Command-to-package mappings per distro family
	declare -A debian_pkgs=(
		[p7zip]='p7zip-full' [wget]='wget' [wrestool]='icoutils'
		[icotool]='icoutils' [convert]='imagemagick'
		[dpkg-deb]='dpkg-dev' [rpmbuild]='rpm'
	)
	declare -A rpm_pkgs=(
		[p7zip]='p7zip p7zip-plugins' [wget]='wget' [wrestool]='icoutils'
		[icotool]='icoutils' [convert]='ImageMagick'
		[dpkg-deb]='dpkg' [rpmbuild]='rpm-build'
	)

	local cmd
	for cmd in $all_deps; do
		if ! check_command "$cmd"; then
			case "$distro_family" in
				debian)
					deps_to_install="$deps_to_install ${debian_pkgs[$cmd]}"
					;;
				rpm)
					deps_to_install="$deps_to_install ${rpm_pkgs[$cmd]}"
					;;
				*)
					echo "Warning: Cannot auto-install '$cmd' on unknown distro. Please install manually." >&2
					;;
			esac
		fi
	done

	if [[ -n $deps_to_install ]]; then
		echo "System dependencies needed:$deps_to_install"

		# Determine if we need sudo (skip if already root)
		local sudo_cmd='sudo'
		if (( EUID == 0 )); then
			sudo_cmd=''
			echo 'Installing as root (no sudo needed)...'
		else
			echo 'Attempting to install using sudo...'
			# Check if we can sudo without a password first
			if sudo -n true 2>/dev/null; then
				echo 'Passwordless sudo detected.'
			elif ! sudo -v; then
				echo 'Failed to validate sudo credentials. Please ensure you can run sudo.' >&2
				exit 1
			fi
		fi

		case "$distro_family" in
			debian)
				if ! $sudo_cmd apt update; then
					echo "Failed to run 'apt update'." >&2
					exit 1
				fi
				# shellcheck disable=SC2086
				if ! $sudo_cmd apt install -y $deps_to_install; then
					echo "Failed to install dependencies using 'apt install'." >&2
					exit 1
				fi
				;;
			rpm)
				# shellcheck disable=SC2086
				if ! $sudo_cmd dnf install -y $deps_to_install; then
					echo "Failed to install dependencies using 'dnf install'." >&2
					exit 1
				fi
				;;
			*)
				echo "Cannot auto-install dependencies on unknown distro." >&2
				echo "Please install these packages manually: $deps_to_install" >&2
				exit 1
				;;
		esac
		echo 'System dependencies installed successfully.'
	fi
}

setup_work_directory() {
	rm -rf "$work_dir"
	mkdir -p "$work_dir" || exit 1
	mkdir -p "$app_staging_dir" || exit 1
}

setup_nodejs() {
	section_header 'Node.js Setup'
	echo 'Checking Node.js version...'

	local node_version_ok=false
	if command -v node &> /dev/null; then
		local node_version node_major
		node_version=$(node --version | cut -d'v' -f2)
		node_major="${node_version%%.*}"
		echo "System Node.js version: v$node_version"

		if (( node_major >= 20 )); then
			echo "System Node.js version is adequate (v$node_version)"
			node_version_ok=true
		else
			echo "System Node.js version is too old (v$node_version). Need v20+"
		fi
	else
		echo 'Node.js not found in system'
	fi

	if [[ $node_version_ok == true ]]; then
		section_footer 'Node.js Setup'
		return 0
	fi

	# Node.js version inadequate - install locally
	echo 'Installing Node.js v20 locally in build directory...'

	local node_arch
	case "$architecture" in
		amd64) node_arch='x64' ;;
		arm64) node_arch='arm64' ;;
		*)
			echo "Unsupported architecture for Node.js: $architecture" >&2
			exit 1
			;;
	esac

	local node_version_to_install='20.18.1'
	local node_tarball="node-v${node_version_to_install}-linux-${node_arch}.tar.xz"
	local node_url="https://nodejs.org/dist/v${node_version_to_install}/${node_tarball}"
	local node_install_dir="$work_dir/node"

	echo "Downloading Node.js v${node_version_to_install} for ${node_arch}..."
	cd "$work_dir" || exit 1
	if ! wget -O "$node_tarball" "$node_url"; then
		echo "Failed to download Node.js from $node_url" >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	# Verify against official Node.js checksums
	local shasums_url node_expected_sha256
	shasums_url="https://nodejs.org/dist/v${node_version_to_install}/SHASUMS256.txt"
	node_expected_sha256=$(
		wget -qO- "$shasums_url" \
			| grep -F "$node_tarball" \
			| awk '{print $1}'
	) || true

	if ! verify_sha256 "$work_dir/$node_tarball" \
		"$node_expected_sha256" 'Node.js tarball'; then
		cd "$project_root" || exit 1
		exit 1
	fi

	echo 'Extracting Node.js...'
	if ! tar -xf "$node_tarball"; then
		echo 'Failed to extract Node.js tarball' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	mv "node-v${node_version_to_install}-linux-${node_arch}" "$node_install_dir" || exit 1
	export PATH="$node_install_dir/bin:$PATH"

	if command -v node &> /dev/null; then
		echo "Local Node.js installed successfully: $(node --version)"
	else
		echo 'Failed to install local Node.js' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	rm -f "$node_tarball"
	cd "$project_root" || exit 1
	section_footer 'Node.js Setup'
}

setup_electron_asar() {
	section_header 'Electron & Asar Handling'

	echo "Ensuring local Electron and Asar installation in $work_dir..."
	cd "$work_dir" || exit 1

	if [[ ! -f package.json ]]; then
		echo "Creating temporary package.json in $work_dir for local install..."
		echo '{"name":"claude-desktop-build","version":"0.0.1","private":true}' > package.json
	fi

	local electron_dist_path="$work_dir/node_modules/electron/dist"
	local asar_bin_path="$work_dir/node_modules/.bin/asar"
	local install_needed=false

	[[ ! -d $electron_dist_path ]] && echo 'Electron distribution not found.' && install_needed=true
	[[ ! -f $asar_bin_path ]] && echo 'Asar binary not found.' && install_needed=true

	if [[ $install_needed == true ]]; then
		echo "Installing Electron and Asar locally into $work_dir..."
		if ! npm install --no-save electron @electron/asar; then
			echo 'Failed to install Electron and/or Asar locally.' >&2
			cd "$project_root" || exit 1
			exit 1
		fi
		echo 'Electron and Asar installation command finished.'
	else
		echo 'Local Electron distribution and Asar binary already present.'
	fi

	if [[ -d $electron_dist_path ]]; then
		echo "Found Electron distribution directory at $electron_dist_path."
		chosen_electron_module_path="$(realpath "$work_dir/node_modules/electron")"
		echo "Setting Electron module path for copying to $chosen_electron_module_path."
	else
		echo "Failed to find Electron distribution directory at '$electron_dist_path' after installation attempt." >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	if [[ -f $asar_bin_path ]]; then
		asar_exec="$(realpath "$asar_bin_path")"
		echo "Found local Asar binary at $asar_exec."
	else
		echo "Failed to find Asar binary at '$asar_bin_path' after installation attempt." >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	cd "$project_root" || exit 1

	if [[ -z $chosen_electron_module_path || ! -d $chosen_electron_module_path ]]; then
		echo 'Critical error: Could not resolve a valid Electron module path to copy.' >&2
		exit 1
	fi

	echo "Using Electron module path: $chosen_electron_module_path"
	echo "Using asar executable: $asar_exec"
	section_footer 'Electron & Asar Handling'
}

#===============================================================================
# Download and Extract Functions
#===============================================================================

download_claude_installer() {
	section_header 'Download the latest Claude executable'

	local claude_exe_path="$work_dir/$claude_exe_filename"

	if [[ -n $local_exe_path ]]; then
		echo "Using local Claude installer: $local_exe_path"
		if [[ ! -f $local_exe_path ]]; then
			echo "Local installer file not found: $local_exe_path" >&2
			exit 1
		fi
		cp "$local_exe_path" "$claude_exe_path" || exit 1
		echo 'Local installer copied to build directory'
	else
		echo "Downloading Claude Desktop installer for $architecture..."
		if ! wget -O "$claude_exe_path" "$claude_download_url"; then
			echo "Failed to download Claude Desktop installer from $claude_download_url" >&2
			exit 1
		fi
		echo "Download complete: $claude_exe_filename"

		if ! verify_sha256 "$claude_exe_path" \
			"$claude_exe_sha256" 'Claude Desktop installer'; then
			exit 1
		fi
	fi

	echo "Extracting resources from $claude_exe_filename into separate directory..."
	claude_extract_dir="$work_dir/claude-extract"
	mkdir -p "$claude_extract_dir" || exit 1

	if ! 7z x -y "$claude_exe_path" -o"$claude_extract_dir"; then
		echo 'Failed to extract installer' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	cd "$claude_extract_dir" || exit 1
	local nupkg_path_relative
	nupkg_path_relative=$(find . -maxdepth 1 -name 'AnthropicClaude-*.nupkg' | head -1)

	if [[ -z $nupkg_path_relative ]]; then
		echo "Could not find AnthropicClaude nupkg file in $claude_extract_dir" >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo "Found nupkg: $nupkg_path_relative (in $claude_extract_dir)"

	version=$(echo "$nupkg_path_relative" | LC_ALL=C grep -oP 'AnthropicClaude-\K[0-9]+\.[0-9]+\.[0-9]+(?=-full|-arm64-full)')
	if [[ -z $version ]]; then
		echo "Could not extract version from nupkg filename: $nupkg_path_relative" >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo "Detected Claude version: $version"

	# Extract wrapper version from release tag if provided (e.g., v1.3.2+claude1.1.799 -> 1.3.2)
	if [[ -n $release_tag ]]; then
		local wrapper_version
		# Extract version between 'v' and '+claude' (e.g., v1.3.2+claude1.1.799 -> 1.3.2)
		wrapper_version=$(echo "$release_tag" | LC_ALL=C grep -oP '^v\K[0-9]+\.[0-9]+\.[0-9]+(?=\+claude)')
		if [[ -n $wrapper_version ]]; then
			version="${version}-${wrapper_version}"
			echo "Package version with wrapper suffix: $version"
		else
			echo "Warning: Could not extract wrapper version from release tag: $release_tag" >&2
		fi
	fi

	if ! 7z x -y "$nupkg_path_relative"; then
		echo 'Failed to extract nupkg' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo 'Resources extracted from nupkg'

	cd "$project_root" || exit 1
}

#===============================================================================
# Patching Functions
#===============================================================================

patch_app_asar() {
	echo 'Processing app.asar...'
	cp "$claude_extract_dir/lib/net45/resources/app.asar" "$app_staging_dir/" || exit 1
	cp -a "$claude_extract_dir/lib/net45/resources/app.asar.unpacked" "$app_staging_dir/" || exit 1
	cd "$app_staging_dir" || exit 1
	"$asar_exec" extract app.asar app.asar.contents || exit 1

	# Frame fix wrapper
	echo 'Creating BrowserWindow frame fix wrapper...'
	local original_main
	original_main=$(node -e "const pkg = require('./app.asar.contents/package.json'); console.log(pkg.main);")
	echo "Original main entry: $original_main"

	cp "$source_dir/scripts/frame-fix-wrapper.js" app.asar.contents/frame-fix-wrapper.js || exit 1

	cat > app.asar.contents/frame-fix-entry.js << EOFENTRY
// Load frame fix first
require('./frame-fix-wrapper.js');
// Then load original main
require('./${original_main}');
EOFENTRY

	# BrowserWindow frame/titleBarStyle patching is handled at runtime by
	# frame-fix-wrapper.js via a Proxy on require('electron'). No sed patches
	# needed — the wrapper detects popup vs main windows by their options and
	# applies frame:true/false accordingly.

	# Update package.json
	echo 'Modifying package.json to load frame fix and add node-pty...'
	node -e "
const fs = require('fs');
const pkg = require('./app.asar.contents/package.json');
pkg.originalMain = pkg.main;
pkg.main = 'frame-fix-entry.js';
pkg.optionalDependencies = pkg.optionalDependencies || {};
pkg.optionalDependencies['node-pty'] = '^1.0.0';
fs.writeFileSync('./app.asar.contents/package.json', JSON.stringify(pkg, null, 2));
console.log('Updated package.json: main entry and node-pty dependency');
"

	# Create stub native module
	echo 'Creating stub native module...'
	mkdir -p app.asar.contents/node_modules/@ant/claude-native || exit 1
	cp "$source_dir/scripts/claude-native-stub.js" \
		app.asar.contents/node_modules/@ant/claude-native/index.js || exit 1

	mkdir -p app.asar.contents/resources/i18n || exit 1
	cp "$claude_extract_dir/lib/net45/resources/"*-*.json app.asar.contents/resources/i18n/ || exit 1

	# Copy tray icons into asar so both packaged (process.resourcesPath)
	# and unpackaged (app.getAppPath()) code paths can find them
	cp "$claude_extract_dir/lib/net45/resources/Tray"* app.asar.contents/resources/ 2>/dev/null || \
		echo 'Warning: No tray icon files found for asar inclusion'

	# Patch title bar detection
	patch_titlebar_detection

	# Extract electron module variable name for tray patches
	extract_electron_variable

	# Fix incorrect nativeTheme variable references
	fix_native_theme_references

	# Patch tray menu handler
	patch_tray_menu_handler

	# Patch tray icon selection
	patch_tray_icon_selection

	# Patch menuBarEnabled to default to true when unset
	patch_menu_bar_default

	# Patch quick window
	patch_quick_window

	# Add Linux Claude Code support
	patch_linux_claude_code

	# Patch Cowork mode for Linux (TypeScript VM client + Unix socket)
	patch_cowork_linux

	# Copy cowork VM service daemon for Linux Cowork mode
	echo 'Installing cowork VM service daemon...'
	cp "$source_dir/scripts/cowork-vm-service.js" \
		app.asar.contents/cowork-vm-service.js || exit 1
	echo 'Cowork VM service daemon installed'
}

patch_titlebar_detection() {
	echo '##############################################################'
	echo "Removing '!' from 'if (\"!\"isWindows && isMainWindow) return null;'"
	echo 'detection flag to enable title bar'

	local search_base='app.asar.contents/.vite/renderer/main_window/assets'
	local target_pattern='MainWindowPage-*.js'

	echo "Searching for '$target_pattern' within '$search_base'..."
	local target_files
	mapfile -t target_files < <(find "$search_base" -type f -name "$target_pattern")
	local num_files=${#target_files[@]}

	case $num_files in
		0)
			echo "Error: No file matching '$target_pattern' found within '$search_base'." >&2
			exit 1
			;;
		1)
			local target_file="${target_files[0]}"
			echo "Found target file: $target_file"
			sed -i -E 's/if\(!([a-zA-Z]+)[[:space:]]*&&[[:space:]]*([a-zA-Z]+)\)/if(\1 \&\& \2)/g' "$target_file"

			if grep -q -E 'if\(![a-zA-Z]+[[:space:]]*&&[[:space:]]*[a-zA-Z]+\)' "$target_file"; then
				echo "Error: Failed to replace patterns in $target_file." >&2
				exit 1
			fi
			echo "Successfully replaced patterns in $target_file"
			;;
		*)
			echo "Error: Expected exactly one file matching '$target_pattern' within '$search_base', but found $num_files." >&2
			exit 1
			;;
	esac
	echo '##############################################################'
}

extract_electron_variable() {
	echo 'Extracting electron module variable name...'
	local index_js='app.asar.contents/.vite/build/index.js'

	electron_var=$(grep -oP '\$?\w+(?=\s*=\s*require\("electron"\))' \
		"$index_js" | head -1)
	if [[ -z $electron_var ]]; then
		electron_var=$(grep -oP '(?<=new )\$?\w+(?=\.Tray\b)' \
			"$index_js" | head -1)
	fi
	if [[ -z $electron_var ]]; then
		echo 'Failed to extract electron variable name' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	electron_var_re="${electron_var//\$/\\$}"
	echo "  Found electron variable: $electron_var"
	echo '##############################################################'
}

fix_native_theme_references() {
	echo 'Fixing incorrect nativeTheme variable references...'
	local index_js='app.asar.contents/.vite/build/index.js'

	local wrong_refs
	mapfile -t wrong_refs < <(
		grep -oP '\$?\w+(?=\.nativeTheme)' "$index_js" \
			| sort -u \
			| grep -Fxv "$electron_var" || true
	)

	if (( ${#wrong_refs[@]} == 0 )); then
		echo '  All nativeTheme references are correct'
		echo '##############################################################'
		return
	fi

	local ref ref_re
	for ref in "${wrong_refs[@]}"; do
		echo "  Replacing: $ref.nativeTheme -> $electron_var.nativeTheme"
		ref_re="${ref//\$/\\$}"
		sed -i -E \
			"s/${ref_re}\.nativeTheme/${electron_var_re}.nativeTheme/g" \
			"$index_js"
	done
	echo '##############################################################'
}

patch_tray_menu_handler() {
	echo 'Patching tray menu handler...'
	local index_js='app.asar.contents/.vite/build/index.js'

	local tray_func tray_var first_const
	tray_func=$(grep -oP \
		'on\("menuBarEnabled",\(\)=>\{\K\w+(?=\(\)\})' "$index_js")
	if [[ -z $tray_func ]]; then
		echo 'Failed to extract tray menu function name' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo "  Found tray function: $tray_func"

	tray_var=$(grep -oP \
		"\}\);let \K\w+(?==null;(?:async )?function ${tray_func})" \
		"$index_js")
	if [[ -z $tray_var ]]; then
		echo 'Failed to extract tray variable name' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo "  Found tray variable: $tray_var"

	sed -i "s/function ${tray_func}(){/async function ${tray_func}(){/g" \
		"$index_js"

	first_const=$(grep -oP \
		"async function ${tray_func}\(\)\{.*?const \K\w+(?==)" \
		"$index_js" | head -1)
	if [[ -z $first_const ]]; then
		echo 'Failed to extract first const in function' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo "  Found first const variable: $first_const"

	# Add mutex guard to prevent concurrent tray rebuilds
	if ! grep -q "${tray_func}._running" "$index_js"; then
		sed -i "s/async function ${tray_func}(){/async function ${tray_func}(){if(${tray_func}._running)return;${tray_func}._running=true;setTimeout(()=>${tray_func}._running=false,1500);/g" \
			"$index_js"
		echo "  Added mutex guard to ${tray_func}()"
	fi

	# Add DBus cleanup delay after tray destroy
	if ! grep -q "await new Promise.*setTimeout" "$index_js" \
		| grep -q "$tray_var"; then
		sed -i "s/${tray_var}\&\&(${tray_var}\.destroy(),${tray_var}=null)/${tray_var}\&\&(${tray_var}.destroy(),${tray_var}=null,await new Promise(r=>setTimeout(r,250)))/g" \
			"$index_js"
		echo "  Added DBus cleanup delay after $tray_var.destroy()"
	fi

	echo 'Tray menu handler patched'
	echo '##############################################################'

	# Skip tray updates during startup (3 second window)
	echo 'Patching nativeTheme handler for startup delay...'
	if ! grep -q '_trayStartTime' "$index_js"; then
		sed -i -E \
			"s/(${electron_var_re}\.nativeTheme\.on\(\s*\"updated\"\s*,\s*\(\)\s*=>\s*\{)/let _trayStartTime=Date.now();\1/g" \
			"$index_js"
		sed -i -E \
			"s/\((\w+\([^)]*\))\s*,\s*${tray_func}\(\)\s*,/(\1,Date.now()-_trayStartTime>3e3\&\&${tray_func}(),/g" \
			"$index_js"
		echo '  Added startup delay check (3 second window)'
	fi
	echo '##############################################################'
}

patch_tray_icon_selection() {
	echo 'Patching tray icon selection for Linux visibility...'
	local index_js='app.asar.contents/.vite/build/index.js'
	local dark_check="${electron_var_re}.nativeTheme.shouldUseDarkColors"

	if grep -qP ':\$?\w+="TrayIconTemplate\.png"' "$index_js"; then
		sed -i -E \
			"s/:(\\\$?\w+)=\"TrayIconTemplate\.png\"/:\1=${dark_check}?\"TrayIconTemplate-Dark.png\":\"TrayIconTemplate.png\"/g" \
			"$index_js"
		echo 'Patched tray icon selection for Linux theme support'
	else
		echo 'Tray icon selection pattern not found or already patched'
	fi
	echo '##############################################################'
}

patch_menu_bar_default() {
	echo 'Patching menuBarEnabled to default to true when unset...'
	local index_js='app.asar.contents/.vite/build/index.js'

	local menu_bar_var
	menu_bar_var=$(grep -oP \
		'const \K\w+(?=\s*=\s*\w+\("menuBarEnabled"\))' \
		"$index_js" | head -1)
	if [[ -z $menu_bar_var ]]; then
		echo '  Could not extract menuBarEnabled variable name'
		echo '##############################################################'
		return
	fi
	echo "  Found menuBarEnabled variable: $menu_bar_var"

	# Change !!var to var!==false so undefined defaults to true
	if grep -qP ",\s*!!${menu_bar_var}\s*\)" "$index_js"; then
		sed -i -E \
			"s/,\s*!!${menu_bar_var}\s*\)/,${menu_bar_var}!==false)/g" \
			"$index_js"
		echo '  Patched menuBarEnabled to default to true'
	else
		echo '  menuBarEnabled pattern not found or already patched'
	fi
	echo '##############################################################'
}

patch_quick_window() {
	if ! grep -q 'e.blur(),e.hide()' app.asar.contents/.vite/build/index.js; then
		sed -i 's/e.hide()/e.blur(),e.hide()/' app.asar.contents/.vite/build/index.js
		echo 'Added blur() call to fix quick window submit issue'
	fi
}

patch_linux_claude_code() {
	local index_js='app.asar.contents/.vite/build/index.js'
	if grep -q 'process.platform==="linux".*linux-arm64.*linux-x64' "$index_js"; then
		echo 'Linux claude code binary support already present'
		return
	fi

	# New format (Claude >= 1.1.3541): getHostPlatform includes arch detection for win32
	# Pattern: if(process.platform==="win32")return e==="arm64"?"win32-arm64":"win32-x64";throw new Error(...)
	if grep -qP 'if\(process\.platform==="win32"\)return \w+==="arm64"\?"win32-arm64":"win32-x64";throw' "$index_js"; then
		sed -i -E 's/if\(process\.platform==="win32"\)return (\w+)==="arm64"\?"win32-arm64":"win32-x64";throw/if(process.platform==="win32")return \1==="arm64"?"win32-arm64":"win32-x64";if(process.platform==="linux")return \1==="arm64"?"linux-arm64":"linux-x64";throw/' "$index_js"
		echo 'Added linux claude code support (new arch-aware format)'
	# Old format (Claude <= 1.1.3363): no arch detection for win32
	elif grep -q 'if(process.platform==="win32")return"win32-x64";' "$index_js"; then
		sed -i 's/if(process.platform==="win32")return"win32-x64";/if(process.platform==="win32")return"win32-x64";if(process.platform==="linux")return process.arch==="arm64"?"linux-arm64":"linux-x64";/' "$index_js"
		echo 'Added linux claude code support (legacy format)'
	else
		echo 'Warning: Could not find getHostPlatform pattern to patch for Linux claude code support'
	fi
}

patch_cowork_linux() {
	echo 'Patching Cowork mode for Linux...'
	local index_js='app.asar.contents/.vite/build/index.js'

	if ! grep -q 'vmClient (TypeScript)' "$index_js"; then
		echo '  Cowork mode code not found in this version, skipping'
		echo '##############################################################'
		return
	fi

	# All complex patches are done via node to avoid shell escaping issues
	# with minified JavaScript. Uses unique string anchors and dynamic
	# variable extraction to be version-agnostic per CLAUDE.md guidelines.
	if ! INDEX_JS="$index_js" SVC_PATH="cowork-vm-service.js" \
		node << 'COWORK_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
let code = fs.readFileSync(indexJs, 'utf8');
let patchCount = 0;

// Helper: extract a balanced block starting at a delimiter.
// Returns the substring from open to close (inclusive), or null.
// Works for {} [] () by specifying the open char.
function extractBlock(str, startIdx, open = '{') {
    const close = { '{': '}', '[': ']', '(': ')' }[open];
    const blockStart = str.indexOf(open, startIdx);
    if (blockStart === -1) return null;
    let depth = 1;
    let pos = blockStart + 1;
    while (depth > 0 && pos < str.length) {
        if (str[pos] === open) depth++;
        else if (str[pos] === close) depth--;
        pos++;
    }
    return depth === 0 ? str.substring(blockStart, pos) : null;
}

// ============================================================
// Patch 1: Platform check - allow Linux through fz()
// Pattern: VAR!=="darwin"&&VAR!=="win32" (unique in platform gate)
// Anchor: appears near 'unsupported_platform' code value
// ============================================================
const platformGateRe = /(\w+)(\s*!==\s*"darwin"\s*&&\s*)\1(\s*!==\s*"win32")/g;
const origCode = code;
code = code.replace(platformGateRe, (match, varName, mid, end) => {
    // Only patch the instance near the "unsupported_platform" code value
    const matchIdx = origCode.indexOf(match);
    const nearbyText = origCode.substring(matchIdx, matchIdx + 200);
    if (nearbyText.includes('unsupported_platform') || nearbyText.includes('Unsupported platform')) {
        return `${varName}${mid}${varName}${end}&&${varName}!=="linux"`;
    }
    return match;
});
if (code !== origCode) {
    console.log('  Patched platform check to allow Linux');
    patchCount++;
} else {
    // Try without backreference (in case minifier uses different var names)
    const simpleRe = /(!=="darwin"\s*&&\s*\w+\s*!=="win32")([\s\S]{0,200}unsupported_platform)/;
    const simpleMatch = code.match(simpleRe);
    if (simpleMatch) {
        const varMatch = simpleMatch[0].match(/(\w+)\s*!==\s*"win32"/);
        if (varMatch) {
            code = code.replace(simpleMatch[1],
                simpleMatch[1] + '&&' + varMatch[1] + '!=="linux"');
            console.log('  Patched platform check to allow Linux (fallback)');
            patchCount++;
        }
    }
}
if (code === origCode) {
    console.error('FATAL: Failed to patch cowork platform gate for Linux.');
    console.error('The app will crash at startup without this patch.');
    console.error('The platform check pattern or nearby anchor text may have changed.');
    process.exit(1);
}

// ============================================================
// Patch 2: Module loading - use TypeScript VM client on Linux
// Anchor: unique string "vmClient (TypeScript)"
// Extracts the win32 platform variable, adds Linux OR condition
// ============================================================
const vmClientLogMatch = code.match(/(\w+)(\s*\?\s*"vmClient \(TypeScript\)")/);
if (vmClientLogMatch) {
    const win32Var = vmClientLogMatch[1];

    // 2a: Patch the log/description line
    // FROM: WIN32VAR?"vmClient (TypeScript)"
    // TO:   (WIN32VAR||process.platform==="linux")?"vmClient (TypeScript)"
    // Use negative lookbehind to avoid double-patching
    const logRe = new RegExp(
        '(?<!\\|\\|process\\.platform==="linux"\\))' +
        win32Var.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') +
        '(\\s*\\?\\s*"vmClient \\(TypeScript\\)")'
    );
    if (logRe.test(code)) {
        code = code.replace(logRe,
            '(' + win32Var + '||process.platform==="linux")$1');
        console.log('  Patched VM client log check for Linux');
        patchCount++;
    }

    // 2b: Patch the actual module assignment
    // Beautified: WIN32VAR ? (df = { vm: bYe }) : (df = ...)
    // Minified:   WIN32VAR?df={vm:bYe}:df=...
    // Handle both: outer parens are optional in minified code
    const assignRe = new RegExp(
        '(?<!\\|\\|process\\.platform==="linux"\\)?)' +
        win32Var.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') +
        '(\\s*\\?\\s*\\(?\\s*\\w+\\s*=\\s*\\{\\s*vm\\s*:\\s*\\w+\\s*\\}\\s*\\)?)'
    );
    if (assignRe.test(code)) {
        code = code.replace(assignRe,
            '(' + win32Var + '||process.platform==="linux")$1');
        console.log('  Patched VM module assignment for Linux');
        patchCount++;
    }
} else {
    console.log('  WARNING: Could not find vmClient variable for module loading patch');
}

// ============================================================
// Patch 3: Socket path - use Unix domain socket on Linux
// Anchor: unique string "cowork-vm-service" in pipe path
// ============================================================
const pipeMatch = code.match(/(\w+)(\s*=\s*)"([^"]*\\\\[^"]*cowork-vm-service[^"]*)"/);
if (pipeMatch) {
    const pipeVar = pipeMatch[1];
    const assign = pipeMatch[2];
    const pipeStr = pipeMatch[3];
    const oldExpr = pipeVar + assign + '"' + pipeStr + '"';
    const newExpr = pipeVar + assign +
        'process.platform==="linux"?' +
        '(process.env.XDG_RUNTIME_DIR||"/tmp")+"/cowork-vm-service.sock"' +
        ':"' + pipeStr + '"';
    code = code.replace(oldExpr, newExpr);
    console.log('  Patched socket path for Linux Unix domain socket');
    patchCount++;
} else {
    console.log('  WARNING: Could not find pipe path for socket patch');
}

// ============================================================
// Patch 4: Bundle manifest - add empty Linux entries to files
// The linux key MUST exist to prevent TypeError when the app
// accesses files["linux"]["x64"] during cowork status checks.
// Empty arrays mean no VM files are downloaded — this is correct
// because the VM backend is non-functional on Linux (bwrap is
// the only working backend and doesn't use VM files).
// Note: [].every() returns true (vacuous truth), so bO() reports
// "Ready" status. This is intentional — it skips the download.
// ============================================================
if (!code.includes('"linux":{') && !code.includes("'linux':{") &&
    !code.includes('linux:{')) {
    const shaRe = /sha\s*:\s*"([a-f0-9]{40})"/;
    const shaMatch = code.match(shaRe);
    if (shaMatch) {
        const shaIdx = code.indexOf(shaMatch[0]);
        const afterSha = code.indexOf('files', shaIdx);
        if (afterSha !== -1 && afterSha - shaIdx < 200) {
            const filesBlock = extractBlock(code, afterSha, '{');
            if (filesBlock) {
                const filesEnd = code.indexOf(filesBlock, afterSha)
                    + filesBlock.length;
                const insertPos = filesEnd - 1;
                const linuxEntry = ',linux:{x64:[],arm64:[]}';
                code = code.substring(0, insertPos) +
                    linuxEntry + code.substring(insertPos);
                console.log('  Added empty Linux entries to' +
                    ' bundle manifest (VM download disabled)');
                patchCount++;
            }
        }
    }
    if (!code.includes('linux:{x64:')) {
        console.log('  WARNING: Could not add Linux bundle' +
            ' manifest entries');
    }
}

// ============================================================
// Patch 5: MSIX check bypass for Linux
// The fz() function checks: if(t==="win32"&&!ga()) for MSIX
// This is already gated to win32, so no change needed.
// ============================================================

// ============================================================
// Patch 6: Auto-launch service daemon on first connection attempt
// Anchor: unique string "VM service not running. The service failed to start."
//
// The retry loop only retries on ENOENT (socket missing). On Linux,
// stale sockets from a previous session give ECONNREFUSED instead,
// which causes an immediate throw with no retry or auto-launch.
//
// Fix: patch the ENOENT check to also match ECONNREFUSED on Linux,
// then inject auto-launch before the retry delay.
// ============================================================
const serviceErrorStr = 'VM service not running. The service failed to start.';
const serviceErrorIdx = code.indexOf(serviceErrorStr);
if (serviceErrorIdx !== -1) {
    // Step 1: Find the ENOENT check and expand it to include ECONNREFUSED
    // Pattern: VAR.code==="ENOENT"
    // Search backwards from the error string to find it
    const searchStart = Math.max(0, serviceErrorIdx - 300);
    const beforeRegion = code.substring(searchStart, serviceErrorIdx);
    const enoentRe = /(\w+)\.code\s*===\s*"ENOENT"/g;
    let enoentMatch;
    let lastEnoent = null;
    while ((enoentMatch = enoentRe.exec(beforeRegion)) !== null) {
        lastEnoent = enoentMatch;
    }
    if (lastEnoent) {
        const enoentStr = lastEnoent[0];
        const errVar = lastEnoent[1];
        const enoentAbsIdx = searchStart + lastEnoent.index;
        // Replace: VAR.code==="ENOENT"
        // With:    (VAR.code==="ENOENT"||process.platform==="linux"&&VAR.code==="ECONNREFUSED")
        const expanded =
            '(' + enoentStr +
            '||process.platform==="linux"&&' + errVar + '.code==="ECONNREFUSED")';
        code = code.substring(0, enoentAbsIdx) +
            expanded +
            code.substring(enoentAbsIdx + enoentStr.length);
        console.log('  Expanded ENOENT check to include ECONNREFUSED on Linux');
    } else {
        console.log('  WARNING: Could not find ENOENT check for ECONNREFUSED expansion');
    }

    // Step 2: Inject auto-launch before the retry delay
    // Re-find serviceErrorStr since indices shifted after step 1
    const newServiceErrorIdx = code.indexOf(serviceErrorStr);
    const searchEnd = Math.min(code.length, newServiceErrorIdx + 300);
    const searchRegion = code.substring(newServiceErrorIdx, searchEnd);
    const retryMatch = searchRegion.match(
        /await new Promise\((\w+)=>\s*setTimeout\(\1,\s*(\w+)\)\)/
    );
    if (retryMatch) {
        const retryStr = retryMatch[0];
        const retryOffset = searchRegion.indexOf(retryStr);
        const retryAbsIdx = newServiceErrorIdx + retryOffset;
        // Inject auto-launch before the retry delay
        // Service script is in app.asar.unpacked/ (not inside asar, since
        // child_process cannot execute scripts from inside an asar).
        // Uses fork() instead of spawn() because process.execPath in Electron
        // is the Electron binary - spawn would trigger "file open" handling
        // instead of executing the script as Node.js.
        const svcPath = process.env.SVC_PATH || 'cowork-vm-service.js';
        // Extract the enclosing function name (Ma or whatever it's
        // minified to) so the dedup guard attaches to it
        const funcSearchStart = Math.max(0, newServiceErrorIdx - 2000);
        const funcRegion = code.substring(funcSearchStart, newServiceErrorIdx);
        // The function is defined as: async function NAME(t,e){...for(let r=0;r<=LIMIT;r++)
        const funcNameRe = /async function (\w+)\s*\(\s*\w+\s*,\s*\w+\s*\)\s*\{[\s\S]*?for\s*\(\s*let/g;
        let funcMatch;
        let retryFuncName = null;
        while ((funcMatch = funcNameRe.exec(funcRegion)) !== null) {
            retryFuncName = funcMatch[1];
        }
        const svcLaunchedGuard = retryFuncName
            ? retryFuncName + '._svcLaunched'
            : '_globalSvcLaunched';
        const autoLaunch =
            'process.platform==="linux"&&!' + svcLaunchedGuard + '&&(' + svcLaunchedGuard + '=true,' +
            '(()=>{try{' +
            'const _d=require("path").join(process.resourcesPath,' +
            '"app.asar.unpacked","' + svcPath + '");' +
            'if(require("fs").existsSync(_d)){' +
            'const _c=require("child_process").fork(_d,[],' +
            '{detached:true,stdio:"ignore",env:{...process.env,' +
            'ELECTRON_RUN_AS_NODE:"1"}});_c.unref()}' +
            '}catch(_e){console.error("[cowork-autolaunch]",_e)}})()),';
        code = code.substring(0, retryAbsIdx) +
            autoLaunch + code.substring(retryAbsIdx);
        console.log('  Added service daemon auto-launch on Linux');
        patchCount++;
    } else {
        console.log('  WARNING: Could not find retry delay for auto-launch patch');
    }
} else {
    console.log('  WARNING: Could not find VM service error string for auto-launch');
}

// ============================================================
// Patch 7: Skip Windows-specific smol-bin.vhdx copy on Linux
// The code already checks: if(process.platform==="win32")
// No change needed - win32-gated code is skipped on Linux.
// ============================================================

// ============================================================
// Patch 8: VM download tmpdir fix for Linux
// On Linux, os.tmpdir() returns /tmp which is often a small
// tmpfs (3-4GB). The VM rootfs download decompresses to ~9GB,
// causing ENOSPC. Patch to use the bundle directory (on real
// disk) instead of tmpfs for the download temp files.
// Anchor: unique string "wvm-" in mkdtemp call
// Strategy: find the bundle dir variable from nearby mkdir(),
// then replace tmpdir() with that variable in the mkdtemp call.
// ============================================================
{
    // Find: MKDTEMP(PATH.join(OS.tmpdir(), "wvm-"))
    // The bundle dir var is used in mkdir(VAR, ...) just before
    const mkdtempRe = /(\w+)\.mkdtemp\(\s*(\w+)\.join\(\s*(\w+)\.tmpdir\(\)\s*,\s*"wvm-"\s*\)\s*\)/;
    const mkdtempMatch = code.match(mkdtempRe);
    if (mkdtempMatch) {
        const [fullMatch, fsVar, pathVar, osVar] = mkdtempMatch;
        // Find the bundle dir variable: mkdir(VAR, { recursive before wvm-
        const mkdtempIdx = code.indexOf(fullMatch);
        const searchStart = Math.max(0, mkdtempIdx - 2000);
        const before = code.substring(searchStart, mkdtempIdx);
        // Look for: mkdir(VARNAME, { recursive
        const mkdirRe = /(\w+)\.mkdir\(\s*(\w+)\s*,\s*\{\s*recursive/g;
        let bundleVar = null;
        let lastMkdir;
        while ((lastMkdir = mkdirRe.exec(before)) !== null) {
            bundleVar = lastMkdir[2];
        }
        if (bundleVar) {
            // Replace os.tmpdir() with the bundle dir variable
            // On Linux, use the bundle dir; on other platforms keep tmpdir
            const replacement =
                `${fsVar}.mkdtemp(${pathVar}.join(` +
                `process.platform==="linux"?${bundleVar}:${osVar}.tmpdir(),` +
                `"wvm-"))`;
            code = code.substring(0, mkdtempIdx) + replacement +
                code.substring(mkdtempIdx + fullMatch.length);
            console.log('  Patched VM download temp dir to use bundle path on Linux');
            patchCount++;
        } else {
            console.log('  WARNING: Could not find bundle dir variable for tmpdir patch');
        }
    } else {
        console.log('  WARNING: Could not find mkdtemp("wvm-") for tmpdir patch');
    }
}

// ============================================================
// Patch 9: Copy smol-bin VHDX on Linux
// The win32 block copies smol-bin then calls _.configure()
// (Windows HCS setup) which causes "Request timed out" on
// Linux (#315). Inject a separate Linux block after the win32
// block that only does the smol-bin copy.
// ============================================================
{
    const anchor = '"[VM:start] Windows VM service configured"';
    const anchorIdx = code.indexOf(anchor);
    if (anchorIdx !== -1) {
        // Find the "}" closing the win32 if-block after the anchor
        const closingBrace = code.indexOf('}', anchorIdx + anchor.length);
        if (closingBrace !== -1) {
            // Scope variables: uX()=arch, Qe=path, i=bundlePath,
            //   ft=fs, vg=stream/pipeline, tt=logger
            const linuxBlock =
                'if(process.platform==="linux"){' +
                'const _la=uX(),' +
                '_ls=Qe.join(process.resourcesPath,`smol-bin.${_la}.vhdx`),' +
                '_ld=Qe.join(i,"smol-bin.vhdx");' +
                'ft.existsSync(_ls)?' +
                '(tt.info(`[VM:start] Copying smol-bin.${_la}.vhdx to bundle (Linux)`),' +
                'await vg.pipeline(ft.createReadStream(_ls),ft.createWriteStream(_ld)),' +
                'tt.info(`[VM:start] smol-bin.${_la}.vhdx copied successfully`))' +
                ':tt.warn(`[VM:start] smol-bin.${_la}.vhdx not found at ${_ls}`)' +
                '}';
            code = code.substring(0, closingBrace + 1) +
                linuxBlock +
                code.substring(closingBrace + 1);
            console.log('  Injected Linux smol-bin copy block (skips _.configure)');
            patchCount++;
        } else {
            console.log('  WARNING: Could not find closing brace after Windows VM service anchor');
        }
    } else {
        console.log('  WARNING: Could not find Windows VM service anchor for smol-bin patch');
    }
}

fs.writeFileSync(indexJs, code);
console.log(`  Applied ${patchCount} cowork patches`);
if (patchCount < 5) {
    console.log('  WARNING: Some patches failed - Cowork mode may not work');
}
COWORK_PATCH
	then
		echo 'WARNING: Cowork Linux patches failed' >&2
		echo 'Cowork mode may not be available on Linux' >&2
	fi

	echo '##############################################################'
}

install_node_pty() {
	section_header 'Installing node-pty for terminal support'

	local pty_src_dir=''

	if [[ -n $node_pty_dir ]]; then
		# Use pre-built node-pty (e.g. from Nix)
		echo "Using pre-built node-pty from $node_pty_dir"
		pty_src_dir="$node_pty_dir"
	else
		# Build node-pty from npm
		node_pty_build_dir="$work_dir/node-pty-build"
		mkdir -p "$node_pty_build_dir" || exit 1
		cd "$node_pty_build_dir" || exit 1
		echo '{"name":"node-pty-build","version":"1.0.0","private":true}' > package.json

		echo 'Installing node-pty (this compiles native module)...'
		if npm install node-pty 2>&1; then
			echo 'node-pty installed successfully'
			pty_src_dir="$node_pty_build_dir/node_modules/node-pty"
		else
			echo 'Failed to install node-pty - terminal features may not work'
		fi
	fi

	if [[ -n $pty_src_dir && -d $pty_src_dir ]]; then
		echo 'Copying node-pty JavaScript files into app.asar.contents...'
		mkdir -p "$app_staging_dir/app.asar.contents/node_modules/node-pty" || exit 1
		cp -r "$pty_src_dir/lib" \
			"$app_staging_dir/app.asar.contents/node_modules/node-pty/" || exit 1
		cp "$pty_src_dir/package.json" \
			"$app_staging_dir/app.asar.contents/node_modules/node-pty/" || exit 1
		echo 'node-pty JavaScript files copied'
	elif [[ -z $pty_src_dir ]]; then
		echo 'node-pty source directory not set'
	else
		echo "node-pty directory not found: $pty_src_dir"
	fi

	cd "$app_staging_dir" || exit 1
	section_footer 'node-pty installation'
}

finalize_app_asar() {
	"$asar_exec" pack app.asar.contents app.asar || exit 1

	mkdir -p "$app_staging_dir/app.asar.unpacked/node_modules/@ant/claude-native" || exit 1
	cp "$source_dir/scripts/claude-native-stub.js" \
		"$app_staging_dir/app.asar.unpacked/node_modules/@ant/claude-native/index.js" || exit 1

	# Copy cowork VM service daemon (must be unpacked for child_process.fork)
	echo 'Copying cowork VM service daemon to unpacked directory...'
	cp "$source_dir/scripts/cowork-vm-service.js" \
		"$app_staging_dir/app.asar.unpacked/cowork-vm-service.js" || exit 1
	echo 'Cowork VM service daemon copied to unpacked'

	# Copy node-pty native binaries
	local pty_release_dir=''
	if [[ -n $node_pty_dir && -d $node_pty_dir/build/Release ]]; then
		pty_release_dir="$node_pty_dir/build/Release"
	elif [[ -n $node_pty_build_dir && -d $node_pty_build_dir/node_modules/node-pty/build/Release ]]; then
		pty_release_dir="$node_pty_build_dir/node_modules/node-pty/build/Release"
	fi

	if [[ -n $pty_release_dir ]]; then
		echo 'Copying node-pty native binaries to unpacked directory...'
		mkdir -p "$app_staging_dir/app.asar.unpacked/node_modules/node-pty/build/Release" || exit 1
		cp -r "$pty_release_dir/"* \
			"$app_staging_dir/app.asar.unpacked/node_modules/node-pty/build/Release/" || exit 1
		chmod +x "$app_staging_dir/app.asar.unpacked/node_modules/node-pty/build/Release/"* 2>/dev/null || true
		echo 'node-pty native binaries copied'
	else
		echo 'node-pty native binaries not found - terminal features may not work'
	fi
}

#===============================================================================
# Staging Functions
#===============================================================================

stage_electron() {
	echo 'Copying chosen electron installation to staging area...'
	mkdir -p "$app_staging_dir/node_modules/" || exit 1
	local electron_dir_name
	electron_dir_name=$(basename "$chosen_electron_module_path")
	echo "Copying from $chosen_electron_module_path to $app_staging_dir/node_modules/"
	cp -a "$chosen_electron_module_path" "$app_staging_dir/node_modules/" || exit 1

	local staged_electron_bin="$app_staging_dir/node_modules/$electron_dir_name/dist/electron"
	if [[ -f $staged_electron_bin ]]; then
		echo "Setting executable permission on staged Electron binary: $staged_electron_bin"
		chmod +x "$staged_electron_bin" || exit 1
	else
		echo "Warning: Staged Electron binary not found at expected path: $staged_electron_bin"
	fi

	# Copy Electron locale files
	local electron_resources_src="$chosen_electron_module_path/dist/resources"
	electron_resources_dest="$app_staging_dir/node_modules/$electron_dir_name/dist/resources"
	if [[ -d $electron_resources_src ]]; then
		echo 'Copying Electron locale resources...'
		mkdir -p "$electron_resources_dest" || exit 1
		cp -a "$electron_resources_src"/* "$electron_resources_dest/" || exit 1
		echo 'Electron locale resources copied'
	else
		echo "Warning: Electron resources directory not found at $electron_resources_src"
	fi
}

process_icons() {
	section_header 'Icon Processing'

	cd "$claude_extract_dir" || exit 1
	local exe_path='lib/net45/claude.exe'
	if [[ ! -f $exe_path ]]; then
		echo "Cannot find claude.exe at expected path: $claude_extract_dir/$exe_path" >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	echo "Extracting application icons from $exe_path..."
	if ! wrestool -x -t 14 "$exe_path" -o claude.ico; then
		echo 'Failed to extract icons from exe' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	if ! icotool -x claude.ico; then
		echo 'Failed to convert icons' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	cp claude_*.png "$work_dir/" || exit 1
	echo "Application icons extracted and copied to $work_dir"

	cd "$project_root" || exit 1

	# Process tray icons
	local claude_locale_src="$claude_extract_dir/lib/net45/resources"
	echo 'Copying and processing tray icon files for Linux...'
	if [[ ! -d $claude_locale_src ]]; then
		echo "Warning: Claude resources directory not found at $claude_locale_src"
		section_footer 'Icon Processing'
		return
	fi

	cp "$claude_locale_src/Tray"* "$electron_resources_dest/" 2>/dev/null || \
		echo 'Warning: No tray icon files found'

	# Find ImageMagick command
	local magick_cmd=''
	command -v magick &> /dev/null && magick_cmd='magick'
	[[ -z $magick_cmd ]] && command -v convert &> /dev/null && magick_cmd='convert'

	if [[ -z $magick_cmd ]]; then
		echo 'Warning: ImageMagick not found - tray icons may appear invisible'
		echo 'Tray icon files copied (unprocessed)'
		section_footer 'Icon Processing'
		return
	fi

	echo "Processing tray icons for Linux visibility (using $magick_cmd)..."
	local icon_file icon_name
	for icon_file in "$electron_resources_dest"/TrayIconTemplate*.png; do
		[[ ! -f $icon_file ]] && continue
		icon_name=$(basename "$icon_file")
		if "$magick_cmd" "$icon_file" -channel A -fx 'a>0?1:0' +channel \
			"PNG32:$icon_file" 2>/dev/null; then
			echo "  Processed $icon_name (100% opaque)"
		else
			echo "  Failed to process $icon_name"
		fi
	done
	echo 'Tray icon files copied and processed'

	section_footer 'Icon Processing'
}

copy_locale_files() {
	local claude_locale_src="$claude_extract_dir/lib/net45/resources"
	echo 'Copying Claude locale JSON files to Electron resources directory...'
	if [[ -d $claude_locale_src ]]; then
		cp "$claude_locale_src/"*-*.json "$electron_resources_dest/" || exit 1
		echo 'Claude locale JSON files copied to Electron resources directory'
	else
		echo "Warning: Claude locale source directory not found at $claude_locale_src"
	fi

	echo "app.asar processed and staged in $app_staging_dir"
}

copy_ssh_helpers() {
	section_header 'SSH Helpers'

	local ssh_src="$claude_extract_dir/lib/net45/resources/claude-ssh"
	local ssh_dest="$electron_resources_dest/claude-ssh"
	local binary_name="claude-ssh-linux-$architecture"

	if [[ ! -d "$ssh_src" ]]; then
		echo "Warning: SSH helpers not found at $ssh_src"
		section_footer 'SSH Helpers'
		return
	fi

	mkdir -p "$ssh_dest" || exit 1
	cp "$ssh_src/version.txt" "$ssh_dest/" || exit 1
	cp "$ssh_src/$binary_name" "$ssh_dest/" || exit 1
	chmod +x "$ssh_dest/$binary_name"

	echo "Copied SSH helper files:"
	echo "  version.txt"
	echo "  $binary_name"

	section_footer 'SSH Helpers'
}

copy_cowork_resources() {
	section_header 'Cowork Resources'

	local resources_src="$claude_extract_dir/lib/net45/resources"

	# Copy cowork-plugin-shim.sh (used by app for MCP plugin sandboxing)
	local shim_src="$resources_src/cowork-plugin-shim.sh"
	if [[ -f $shim_src ]]; then
		cp "$shim_src" "$electron_resources_dest/cowork-plugin-shim.sh"
		chmod +x "$electron_resources_dest/cowork-plugin-shim.sh"
		echo "Copied cowork-plugin-shim.sh"
	else
		echo "Warning: cowork-plugin-shim.sh not found at $shim_src"
	fi

	# Copy smol-bin VHDX (contains SDK binaries for KVM guest VM).
	# The app copies this from resources to the bundle dir at startup
	# (win32-gated; our index.js patch extends this to Linux).
	# App looks for smol-bin.{arch}.vhdx where arch is x64 or arm64.
	local smol_arch='x64'
	if [[ $architecture == 'arm64' ]]; then
		smol_arch='arm64'
	fi
	local smol_vhdx="$resources_src/smol-bin.${smol_arch}.vhdx"
	if [[ -f $smol_vhdx ]]; then
		cp "$smol_vhdx" \
			"$electron_resources_dest/smol-bin.${smol_arch}.vhdx"
		echo "Copied smol-bin.${smol_arch}.vhdx"
	else
		echo "Warning: smol-bin VHDX not found at $smol_vhdx"
		echo "KVM Cowork will rely on virtiofs for SDK access"
	fi

	section_footer 'Cowork Resources'
}

#===============================================================================
# Packaging Functions
#===============================================================================

run_packaging() {
	section_header 'Call Packaging Script'

	if [[ $build_format == 'nix' ]]; then
		echo 'Nix build mode - skipping packaging (Nix derivation handles installation)'
		section_footer 'Call Packaging Script'
		return 0
	fi

	local output_path=''
	local script_name file_pattern pkg_file

	case "$build_format" in
		deb)
			script_name='build-deb-package.sh'
			file_pattern="${PACKAGE_NAME}_${version}_${architecture}.deb"
			;;
		rpm)
			script_name='build-rpm-package.sh'
			file_pattern="${PACKAGE_NAME}-${version}*.rpm"
			;;
		appimage)
			script_name='build-appimage.sh'
			file_pattern="${PACKAGE_NAME}-${version}-${architecture}.AppImage"
			;;
	esac

	if [[ $build_format == 'deb' || $build_format == 'rpm' ]]; then
		echo "Calling ${build_format^^} packaging script for $architecture..."
		chmod +x "scripts/$script_name" || exit 1
		if ! "scripts/$script_name" \
			"$version" "$architecture" "$work_dir" "$app_staging_dir" \
			"$PACKAGE_NAME" "$MAINTAINER" "$DESCRIPTION"; then
			echo "${build_format^^} packaging script failed." >&2
			exit 1
		fi

		pkg_file=$(find "$work_dir" -maxdepth 1 -name "$file_pattern" | head -n 1)
		echo "${build_format^^} Build complete!"
		if [[ -n $pkg_file && -f $pkg_file ]]; then
			output_path="./$(basename "$pkg_file")"
			mv "$pkg_file" "$output_path" || exit 1
			echo "Package created at: $output_path"
		else
			echo "Warning: Could not determine final .${build_format} file path."
			output_path='Not Found'
		fi

	elif [[ $build_format == 'appimage' ]]; then
		echo "Calling AppImage packaging script for $architecture..."
		chmod +x scripts/build-appimage.sh || exit 1
		if ! scripts/build-appimage.sh \
			"$version" "$architecture" "$work_dir" "$app_staging_dir" "$PACKAGE_NAME"; then
			echo 'AppImage packaging script failed.' >&2
			exit 1
		fi

		local appimage_file
		appimage_file=$(find "$work_dir" -maxdepth 1 -name "${PACKAGE_NAME}-${version}-${architecture}.AppImage" | head -n 1)
		echo 'AppImage Build complete!'
		if [[ -n $appimage_file && -f $appimage_file ]]; then
			output_path="./$(basename "$appimage_file")"
			mv "$appimage_file" "$output_path" || exit 1
			echo "Package created at: $output_path"

			section_header 'Generate .desktop file for AppImage'
			local desktop_file="./${PACKAGE_NAME}-appimage.desktop"
			echo "Generating .desktop file for AppImage at $desktop_file..."
			cat > "$desktop_file" << EOF
[Desktop Entry]
Name=Claude (AppImage)
Comment=Claude Desktop (AppImage Version $version)
Exec=$(basename "$output_path") %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;Network;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
X-AppImage-Version=$version
X-AppImage-Name=Claude Desktop (AppImage)
EOF
			echo '.desktop file generated.'
		else
			echo 'Warning: Could not determine final .AppImage file path.'
			output_path='Not Found'
		fi
	fi

	# Store for print_next_steps
	final_output_path="$output_path"
}

cleanup_build() {
	section_header 'Cleanup'
	if [[ $perform_cleanup != true ]]; then
		echo "Skipping cleanup of intermediate build files in $work_dir."
		return
	fi

	echo "Cleaning up intermediate build files in $work_dir..."
	if rm -rf "$work_dir"; then
		echo "Cleanup complete ($work_dir removed)."
	else
		echo 'Cleanup command failed.'
	fi
}

print_next_steps() {
	echo -e '\n\033[1;34m====== Next Steps ======\033[0m'

	case "$build_format" in
		deb|rpm)
			if [[ $final_output_path != 'Not Found' && -e $final_output_path ]]; then
				local pkg_type install_cmd alt_cmd
				if [[ $build_format == 'deb' ]]; then
					pkg_type='Debian'
					install_cmd="sudo apt install $final_output_path"
					alt_cmd="sudo dpkg -i $final_output_path"
				else
					pkg_type='RPM'
					install_cmd="sudo dnf install $final_output_path"
					alt_cmd="sudo rpm -i $final_output_path"
				fi
				echo -e "To install the $pkg_type package, run:"
				echo -e "   \033[1;32m$install_cmd\033[0m"
				echo -e "   (or \`$alt_cmd\`)"
			else
				echo -e "${build_format^^} package file not found. Cannot provide installation instructions."
			fi
			;;
		appimage)
		if [[ $final_output_path != 'Not Found' && -e $final_output_path ]]; then
			echo -e "AppImage created at: \033[1;36m$final_output_path\033[0m"
			echo -e '\n\033[1;33mIMPORTANT:\033[0m This AppImage requires \033[1;36mGear Lever\033[0m for proper desktop integration'
			# shellcheck disable=SC2016  # backticks intentional for display
		echo -e 'and to handle the `claude://` login process correctly.'
			echo -e '\nTo install Gear Lever:'
			echo -e '   1. Install via Flatpak:'
			echo -e '      \033[1;32mflatpak install flathub it.mijorus.gearlever\033[0m'
			echo -e '   2. Integrate your AppImage with just one click:'
			echo -e '      - Open Gear Lever'
			echo -e "      - Drag and drop \033[1;36m$final_output_path\033[0m into Gear Lever"
			echo -e "      - Click 'Integrate' to add it to your app menu"
			if [[ ${GITHUB_ACTIONS:-} == 'true' ]]; then
				echo -e '\n   This AppImage includes embedded update information!'
			else
				echo -e '\n   This locally-built AppImage does not include update information.'
				echo -e '   For automatic updates, download release versions: https://github.com/aaddrick/claude-desktop-debian/releases'
			fi
		else
			echo -e 'AppImage file not found. Cannot provide usage instructions.'
		fi
			;;
	esac

	echo -e '\033[1;34m======================\033[0m'
}

#===============================================================================
# Main Execution
#===============================================================================

main() {
	# Phase 1: Setup
	detect_architecture
	detect_distro
	check_system_requirements
	parse_arguments "$@"

	# Early exit for test mode
	if [[ $test_flags_mode == true ]]; then
		echo '--- Test Flags Mode Enabled ---'
		echo "Build Format: $build_format"
		echo "Clean Action: $cleanup_action"
		echo 'Exiting without build.'
		exit 0
	fi

	if [[ $build_format != 'nix' ]]; then
		check_dependencies
	fi
	setup_work_directory

	if [[ $build_format != 'nix' ]]; then
		setup_nodejs
		setup_electron_asar
	else
		# Nix provides node and asar in PATH
		asar_exec=$(command -v asar)
		if [[ -z $asar_exec ]]; then
			echo 'Error: asar not found in PATH (expected Nix to provide it)' >&2
			exit 1
		fi
	fi

	# Phase 2: Download and extract
	if [[ $build_format == 'nix' && -z $local_exe_path ]]; then
		echo 'Error: --exe is required when --build nix is specified' >&2
		exit 1
	fi
	download_claude_installer

	# Phase 3: Patch and prepare
	patch_app_asar
	install_node_pty
	finalize_app_asar
	if [[ $build_format != 'nix' ]]; then
		stage_electron
		copy_locale_files
	else
		# Nix installPhase handles Electron staging and locale files.
		# Set a resources destination so process_icons and copy_ssh_helpers
		# have somewhere to write; the Nix installPhase picks them up.
		electron_resources_dest="$app_staging_dir/nix-resources"
		mkdir -p "$electron_resources_dest" || exit 1
	fi
	process_icons
	copy_ssh_helpers
	copy_cowork_resources

	cd "$project_root" || exit 1

	# Phase 4: Package
	run_packaging

	# Phase 5: Cleanup and finish
	cleanup_build

	echo 'Build process finished.'
	if [[ $build_format != 'nix' ]]; then
		print_next_steps
	fi
}

# Run main with all script arguments
main "$@"

exit 0
