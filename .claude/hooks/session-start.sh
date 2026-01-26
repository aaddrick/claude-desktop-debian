#!/usr/bin/env bash
#
# SessionStart hook: Install critical tools for Claude Code sessions
#
# Ensures jq, shellcheck, actionlint, and gh are available for hooks
# and development workflows. Primarily targets remote/web sessions.

# SC2024: sudo doesn't affect redirects - intentional, log file should be
# owned by user not root since it's in $HOME/.cache
# shellcheck disable=SC2024

# Log file for debugging
log_file="$HOME/.cache/claude-desktop-debian/session-start.log"
mkdir -p "$(dirname "$log_file")"

log() {
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$log_file"
}

log 'Session start hook triggered'
log "CLAUDE_CODE_REMOTE=$CLAUDE_CODE_REMOTE"

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

install_actionlint() {
	if command -v actionlint &>/dev/null; then
		skipped+=('actionlint')
		return 0
	fi

	log 'Installing actionlint from GitHub releases...'

	# Extract download URL without GNU-specific grep options
	local json url
	json=$(curl -s https://api.github.com/repos/rhysd/actionlint/releases/latest)
	# Find the linux_amd64.tar.gz URL from the JSON
	url=$(printf '%s' "$json" | grep -o '"browser_download_url"[^}]*linux_amd64\.tar\.gz"' \
		| grep -o 'https://[^"]*')

	if [[ -z $url ]]; then
		log 'Failed to get actionlint download URL'
		failed+=('actionlint')
		return 1
	fi

	if curl -sL "$url" | sudo tar xz -C /usr/local/bin actionlint; then
		installed+=('actionlint')
		return 0
	else
		log 'Failed to install actionlint'
		failed+=('actionlint')
		return 1
	fi
}

install_gh() {
	if command -v gh &>/dev/null; then
		skipped+=('gh')
		return 0
	fi

	log 'Installing GitHub CLI...'

	# Add GitHub CLI repository
	local keyring='/usr/share/keyrings/githubcli-archive-keyring.gpg'
	if [[ ! -f "$keyring" ]]; then
		curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
			| sudo tee "$keyring" > /dev/null
		printf 'deb [arch=%s signed-by=%s] %s stable main\n' \
			"$(dpkg --print-architecture)" \
			"$keyring" \
			'https://cli.github.com/packages' \
			| sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
		sudo apt-get update -qq >> "$log_file" 2>&1
	fi

	if sudo apt-get install -y -qq gh >> "$log_file" 2>&1; then
		installed+=('gh')
		return 0
	else
		log 'Failed to install gh'
		failed+=('gh')
		return 1
	fi
}

main() {
	# Update apt cache once at the start
	log 'Updating apt cache...'
	sudo apt-get update -qq >> "$log_file" 2>&1

	# Install critical tools
	install_apt_package 'jq'
	install_apt_package 'shellcheck'
	install_actionlint
	install_gh

	# Report results
	local msg=''
	if ((${#installed[@]} > 0)); then
		msg="Installed: ${installed[*]}"
	fi
	if ((${#skipped[@]} > 0)); then
		[[ -n $msg ]] && msg+='. '
		msg+="Already present: ${skipped[*]}"
	fi
	if ((${#failed[@]} > 0)); then
		[[ -n $msg ]] && msg+='. '
		msg+="Failed: ${failed[*]}"
	fi

	log "$msg"
	printf '%s\n' "$msg"
}

main
exit 0
