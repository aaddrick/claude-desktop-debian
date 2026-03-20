#!/usr/bin/env bash

# Auto-update Claude Code CLI via `claude update`
# Safe: skips update if active Claude Code sessions are detected.
#
# Usage: auto-update-claude-code.sh [--force] [--dry-run]
#   --force    Skip running-session safety checks
#   --dry-run  Show what would happen; make no changes
#
# Optional ntfy notifications (silently skipped if server unreachable):
#   NTFY_URL    ntfy server base URL  (default: http://localhost:2586)
#   NTFY_TOPIC  ntfy topic to publish (default: claude-updates)

log_dir="${HOME}/.local/log/claude-updates"
log_file="$log_dir/claude-code.log"

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

# Return 0 (true) if active Claude Code sessions appear to be running.
# We look for node processes running the claude CLI, excluding:
#   - claude-desktop (Electron app)
#   - auto-update scripts themselves
#   - this script's own process tree
is_claude_code_active() {
	local our_pid=$$
	local found=false

	while IFS= read -r pid; do
		[[ -z $pid ]] && continue
		(( pid == our_pid )) && continue

		local args
		args=$(ps -p "$pid" -o args= 2>/dev/null) || continue

		# Skip claude-desktop (Electron / .mount_claude*)
		[[ $args == *claude-desktop* ]] && continue
		[[ $args == *mount_claude* ]] && continue
		# Skip auto-update processes
		[[ $args == *auto-update* ]] && continue
		# Skip grep/pgrep calls
		[[ $args == *pgrep* || $args == *grep* ]] && continue

		found=true
		break
	done < <(pgrep -f 'claude' 2>/dev/null)

	$found
}

# Return the current `claude --version` string.
claude_version() {
	claude --version 2>/dev/null || true
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
				echo 'Usage: auto-update-claude-code.sh [--force] [--dry-run]'
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

	log '=== Claude Code update check starting ==='
	$dry_run && log '[DRY RUN mode]'

	# Verify claude is available
	if ! command -v claude > /dev/null 2>&1; then
		log 'ERROR: claude command not found in PATH'
		return 1
	fi

	local version_before
	version_before=$(claude_version)
	log "Current version: $version_before"

	# --- Safety check ---
	if ! $force; then
		if is_claude_code_active; then
			log 'Skipping: active Claude Code sessions detected'
			return 0
		fi
	else
		log 'Safety checks bypassed (--force)'
	fi

	if $dry_run; then
		log '[DRY RUN] Would run: claude update'
		return 0
	fi

	# --- Update ---
	log 'Running: claude update'
	local output status
	output=$(claude update 2>&1)
	status=$?

	if (( status != 0 )); then
		log "ERROR: claude update failed (exit $status)"
		log "Output: $output"
		notify 'Claude Code Update Failed' \
			"claude update exited $status" 'high'
		return $status
	fi

	log "Update output: $output"

	local version_after
	version_after=$(claude_version)

	if [[ $version_before != "$version_after" ]]; then
		log "Updated: $version_before -> $version_after"
		notify 'Claude Code Updated' \
			"$version_before -> $version_after" 'low'
	else
		log "Already up to date: $version_after"
	fi

	return 0
}

main "$@"
