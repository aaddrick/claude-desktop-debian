#!/usr/bin/env bash
#
# Install build and extraction tools for Claude Desktop Debian
#
# These tools are needed for running build.sh to build .deb and AppImage
# packages. Can be run manually via the /setup-build-tools skill or
# sourced by session-start.sh for full environment setup.

# SC2024: sudo doesn't affect redirects - intentional, log file should be
# owned by user not root since it's in $HOME/.cache
# shellcheck disable=SC2024

# Log file for debugging
log_file="$HOME/.cache/claude-desktop-debian/session-start.log"
mkdir -p "$(dirname "$log_file")"

log() {
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$log_file"
}

log 'Build tools installation triggered'

# Track what we install
installed=()
skipped=()
failed=()

install_apt_package() {
	local cmd="$1"
	local pkg="${2:-$1}"

	if command -v "$cmd" &>/dev/null; then
		skipped+=("$cmd")
		return 0
	fi

	log "Installing $pkg via apt..."
	if sudo apt-get install -y -qq "$pkg" >> "$log_file" 2>&1; then
		installed+=("$cmd")
		return 0
	else
		log "Failed to install $pkg"
		failed+=("$cmd")
		return 1
	fi
}

check_imagemagick() {
	# ImageMagick can be either 'convert' (v6) or 'magick' (v7)
	if command -v convert &>/dev/null || command -v magick &>/dev/null; then
		skipped+=('imagemagick')
		return 0
	fi
	return 1
}

install_imagemagick() {
	if check_imagemagick; then
		return 0
	fi

	log 'Installing imagemagick via apt...'
	if sudo apt-get install -y -qq imagemagick >> "$log_file" 2>&1; then
		installed+=('imagemagick')
		return 0
	else
		log 'Failed to install imagemagick'
		failed+=('imagemagick')
		return 1
	fi
}

install_node() {
	if command -v node &>/dev/null; then
		local version_str version
		version_str=$(node --version 2>/dev/null)
		# Extract major version: v20.10.0 -> 20
		version=${version_str#v}
		version=${version%%.*}
		if ((version >= 20)); then
			skipped+=('node')
			return 0
		fi
		log "Node.js version $version is too old, need v20+"
	fi

	log 'Installing Node.js v20 via NodeSource...'

	# Add NodeSource repository for Node.js 20
	if curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >> "$log_file" 2>&1; then
		if sudo apt-get install -y -qq nodejs >> "$log_file" 2>&1; then
			installed+=('node')
			return 0
		fi
	fi

	log 'Failed to install Node.js'
	failed+=('node')
	return 1
}

main() {
	log 'Updating apt cache...'
	sudo apt-get update -qq >> "$log_file" 2>&1

	# Extraction tools
	install_apt_package '7z' 'p7zip-full'
	install_apt_package 'wget'

	# Icon processing
	install_apt_package 'wrestool' 'icoutils'
	install_imagemagick

	# Debian packaging
	install_apt_package 'dpkg-deb' 'dpkg-dev'

	# libfuse2 for AppImage (package name varies)
	if ! dpkg -l libfuse2 &>/dev/null && ! dpkg -l libfuse2t64 &>/dev/null; then
		log 'Installing libfuse2 for AppImage support...'
		# Try libfuse2t64 first (Ubuntu 24.04+), fall back to libfuse2
		if ! sudo apt-get install -y -qq libfuse2t64 >> "$log_file" 2>&1; then
			sudo apt-get install -y -qq libfuse2 >> "$log_file" 2>&1
		fi
		installed+=('libfuse2')
	else
		skipped+=('libfuse2')
	fi

	# Node.js for npm/asar operations
	install_node

	# Report results
	local msg='Build tools setup complete.'
	if ((${#installed[@]} > 0)); then
		msg+=" Installed: ${installed[*]}."
	fi
	if ((${#skipped[@]} > 0)); then
		msg+=" Already present: ${skipped[*]}."
	fi
	if ((${#failed[@]} > 0)); then
		msg+=" Failed: ${failed[*]}."
	fi

	log "$msg"
	printf '%s\n' "$msg"
}

main
exit 0
