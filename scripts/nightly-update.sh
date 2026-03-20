#!/usr/bin/env bash

# Nightly orchestrator: updates Claude Desktop and Claude Code CLI.
# Designed to run unattended at 03:00 via cron.
#
# Usage: nightly-update.sh [--force] [--dry-run]
#   --force    Pass --force to all sub-scripts (skip safety checks)
#   --dry-run  Pass --dry-run to all sub-scripts; no changes made
#
# Optional ntfy notifications (silently skipped if server unreachable):
#   NTFY_URL    ntfy server base URL  (default: http://localhost:2586)
#   NTFY_TOPIC  ntfy topic to publish (default: claude-updates)
#
# Suggested cron entry:
#   7 3 * * * /path/to/claude-desktop-debian/scripts/nightly-update.sh
#
# Sudoers note: the desktop update installs a .deb with sudo.
# To allow passwordless install, add to /etc/sudoers.d/claude-updates:
#   your-username ALL=(ALL) NOPASSWD: /usr/bin/apt install *

# Resolve scripts directory from this script's location.
scripts_dir="${SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
log_dir="${HOME}/.local/log/claude-updates"
log_file="$log_dir/nightly.log"

# Source NVM so `claude` is on the PATH in cron's minimal environment.
# shellcheck disable=SC1091
[[ -s "${NVM_DIR:-${HOME}/.nvm}/nvm.sh" ]] \
	&& \. "${NVM_DIR:-${HOME}/.nvm}/nvm.sh"

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

# Run a sub-script, capture its output, return its exit status.
# Usage: run_script <label> <script-path> [extra-flags...]
# Sets: last_output (stdout+stderr of the sub-script)
run_script() {
	local label="$1"
	local script="$2"
	shift 2

	if [[ ! -x $script ]]; then
		last_output="Script not found or not executable: $script"
		log "ERROR [$label]: $last_output"
		return 1
	fi

	log "Starting: $label"
	last_output=$("$script" "$@" 2>&1)
	local status=$?
	while IFS= read -r line; do
		[[ -n $line ]] && log "  [$label] $line"
	done <<< "$last_output"
	return $status
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
				echo 'Usage: nightly-update.sh [--force] [--dry-run]'
				echo ''
				echo 'Options:'
				echo '  --force    Skip running-process safety checks'
				echo '  --dry-run  Show what would happen; make no changes'
				echo ''
				echo 'Environment:'
				echo '  NTFY_URL    ntfy server URL (default: http://localhost:2586)'
				echo '  NTFY_TOPIC  ntfy topic     (default: claude-updates)'
				echo '  NVM_DIR     NVM install dir (default: ~/.nvm)'
				echo '  SCRIPTS_DIR Override scripts directory (auto-detected)'
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

	# Build flags to pass through to sub-scripts.
	local flags=()
	$dry_run && flags+=('--dry-run')
	$force   && flags+=('--force')

	log '================================================'
	log "=== Nightly update starting${flags:+ (${flags[*]})} ==="
	log '================================================'

	local code_status=0
	local desktop_status=0

	# 1. Update Claude Code CLI first (faster, lower risk).
	run_script 'Claude Code CLI' \
		"$scripts_dir/auto-update-claude-code.sh" \
		"${flags[@]}"
	code_status=$?

	# 2. Update Claude Desktop (slower: downloads, builds, installs .deb).
	run_script 'Claude Desktop' \
		"$scripts_dir/auto-update-desktop.sh" \
		"${flags[@]}"
	desktop_status=$?

	# --- Summary ---
	log '--- Summary ---'
	if (( code_status == 0 )); then
		log "Claude Code CLI:   OK"
	else
		log "Claude Code CLI:   FAILED (exit $code_status)"
	fi
	if (( desktop_status == 0 )); then
		log "Claude Desktop:    OK"
	else
		log "Claude Desktop:    FAILED (exit $desktop_status)"
	fi

	local overall=0
	(( code_status != 0 || desktop_status != 0 )) && overall=1

	local summary_body
	summary_body="Code CLI: $(
		(( code_status == 0 )) && echo OK || echo "FAIL($code_status)"
	) | Desktop: $(
		(( desktop_status == 0 )) && echo OK || echo "FAIL($desktop_status)"
	)"

	if (( overall == 0 )); then
		log 'All updates completed successfully'
		notify 'Claude Nightly Updates OK' "$summary_body" 'low'
	else
		log "One or more updates failed"
		notify 'Claude Nightly Updates FAILED' "$summary_body" 'high'
	fi

	log '=== Nightly update complete ==='
	return $overall
}

main "$@"
