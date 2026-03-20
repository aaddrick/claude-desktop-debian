#!/usr/bin/env bash

# Auto-update Claude Desktop from the community fork.
# Checks for a newer version, builds the .deb, and installs it.
# Safe: only updates if Claude Desktop is not running.
#
# Usage: auto-update-desktop.sh [--force] [--dry-run]
#   --force    Skip running-process safety checks
#   --dry-run  Show what would happen; make no changes
#
# Optional ntfy notifications (silently skipped if server unreachable):
#   NTFY_URL    ntfy server base URL  (default: http://localhost:2586)
#   NTFY_TOPIC  ntfy topic to publish (default: claude-updates)
#
# Sudoers note: unattended install requires passwordless sudo for apt.
# Add to /etc/sudoers.d/claude-updates:
#   your-username ALL=(ALL) NOPASSWD: /usr/bin/apt install *

# Resolve repo root from this script's location (scripts/ subdir)
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log_dir="${HOME}/.local/log/claude-updates"
log_file="$log_dir/claude-desktop.log"

dry_run=false
force=false

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

log() {
	local msg
	msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
	echo "$msg"
	echo "$msg" >> "$log_file"
}

notify() {
	# Send an ntfy notification; silently skip if the server is down.
	# Configure via NTFY_URL / NTFY_TOPIC env vars.
	local title="$1"
	local body="$2"
	local priority="${3:-default}"
	local url="${NTFY_URL:-http://localhost:2586}"
	local topic="${NTFY_TOPIC:-claude-updates}"
	curl -s --max-time 5 \
		-H "Title: $title" \
		-H "Priority: $priority" \
		-d "$body" \
		"$url/$topic" > /dev/null 2>&1 || true
}

# Return 0 (true) if Claude Desktop is currently running.
is_desktop_running() {
	pgrep -f 'claude-desktop\|Claude Desktop\|electron.*claude' \
		> /dev/null 2>&1
}

# Return 0 (true) if Dispatch/Cowork VM agents are active.
is_cowork_active() {
	pgrep -f 'bwrap\|bubblewrap\|cowork-vm' > /dev/null 2>&1
}

# Print the installed claude-desktop package version, or empty string.
installed_version() {
	dpkg-query -W -f='${Version}' claude-desktop 2>/dev/null || true
}

# Print the latest version embedded in build.sh on origin/main.
latest_version() {
	# Fetch quietly so we get the freshest data from the remote.
	git -C "$repo_dir" fetch --quiet origin main 2>/dev/null || true
	git -C "$repo_dir" show origin/main:build.sh 2>/dev/null \
		| grep -oP 'x64/\K[0-9]+\.[0-9]+\.[0-9]+' \
		| head -1
}

# ------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------

parse_args() {
	while (( $# > 0 )); do
		case "$1" in
			--force)   force=true;   shift ;;
			--dry-run) dry_run=true; shift ;;
			-h|--help)
				echo 'Usage: auto-update-desktop.sh [--force] [--dry-run]'
				exit 0
				;;
			*)
				echo "Unknown option: $1" >&2
				exit 1
				;;
		esac
	done
}

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------

main() {
	parse_args "$@"
	mkdir -p "$log_dir"

	log "=== Claude Desktop update check starting ==="
	$dry_run && log '[DRY RUN mode]'

	# --- Safety checks ---
	if ! $force; then
		if is_desktop_running; then
			log 'Skipping: Claude Desktop is currently running'
			return 0
		fi
		if is_cowork_active; then
			log 'Skipping: Dispatch/Cowork agents are active'
			return 0
		fi
	else
		log 'Safety checks bypassed (--force)'
	fi

	# --- Version comparison ---
	local current
	current=$(installed_version)
	log "Installed version: ${current:-none}"

	local latest
	latest=$(latest_version)
	if [[ -z $latest ]]; then
		log 'ERROR: Could not determine latest version from origin/main'
		notify 'Claude Desktop Update Failed' \
			'Could not determine latest version' 'high'
		return 1
	fi
	log "Latest version: $latest"

	if [[ $current == "$latest" ]]; then
		log 'Already up to date; nothing to do'
		return 0
	fi

	log "Update available: $current -> $latest"

	if $dry_run; then
		log "[DRY RUN] Would: git pull, build .deb, sudo apt install"
		return 0
	fi

	# --- Pull latest main branch ---
	log 'Pulling latest changes from origin/main...'
	if ! git -C "$repo_dir" checkout main 2>&1 | tee -a "$log_file"; then
		log 'WARNING: git checkout main failed; continuing on current branch'
	fi
	if ! git -C "$repo_dir" pull origin main 2>&1 | tee -a "$log_file"; then
		log 'ERROR: git pull failed'
		notify 'Claude Desktop Update Failed' 'git pull failed' 'high'
		return 1
	fi

	# --- Build .deb ---
	log 'Building .deb package (this takes several minutes)...'
	local build_log="$log_dir/build-$latest.log"
	if ! (cd "$repo_dir" && bash build.sh --build deb) \
			> "$build_log" 2>&1; then
		log "ERROR: build.sh failed; see $build_log"
		notify 'Claude Desktop Build Failed' \
			"v$latest build failed; check $build_log" 'high'
		return 1
	fi
	log 'Build succeeded'

	# --- Install ---
	local deb_file="$repo_dir/claude-desktop_${latest}_amd64.deb"
	if [[ ! -f $deb_file ]]; then
		# Try arm64 on non-x86 systems
		deb_file="$repo_dir/claude-desktop_${latest}_arm64.deb"
	fi
	if [[ ! -f $deb_file ]]; then
		log "ERROR: Expected .deb not found after build: $deb_file"
		notify 'Claude Desktop Install Failed' \
			"Built .deb not found for v$latest" 'high'
		return 1
	fi

	log "Installing $deb_file..."
	if ! sudo -n apt install -y "$deb_file" 2>&1 | tee -a "$log_file"; then
		log 'ERROR: apt install failed (may need NOPASSWD sudo config)'
		log 'To enable passwordless install, add to /etc/sudoers.d/:'
		log '  your-username ALL=(ALL) NOPASSWD: /usr/bin/apt install *'
		notify 'Claude Desktop Install Failed' \
			"sudo apt install failed for v$latest" 'high'
		return 1
	fi

	local new_ver
	new_ver=$(installed_version)
	log "Installation complete: now at $new_ver"
	notify 'Claude Desktop Updated' \
		"$current -> $new_ver" 'low'

	return 0
}

main "$@"
