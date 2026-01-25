#!/usr/bin/env bash
#
# PreToolUse hook: Run shellcheck and actionlint before git push
#
# Checks shell scripts and GitHub Actions workflows for issues
# before allowing git push to proceed.

set -o pipefail

# Read JSON input from stdin
input=$(</dev/stdin)

# Extract tool name and command
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')

# Only process Bash tool calls
if [[ "$tool_name" != 'Bash' ]]; then
	exit 0
fi

# Only process git push commands
if [[ "$command" != *'git push'* ]]; then
	exit 0
fi

errors=''

check_shellcheck() {
	local scripts="$1"
	local script result

	if ! command -v shellcheck &>/dev/null; then
		echo 'Warning: shellcheck not installed, skipping shell script checks' >&2
		return
	fi

	while IFS= read -r script; do
		if [[ -f "$script" ]]; then
			result=$(shellcheck -f gcc "$script" 2>&1) || true
			if [[ -n "$result" ]]; then
				errors+="shellcheck issues in $script:"$'\n'"$result"$'\n\n'
			fi
		fi
	done <<< "$scripts"
}

check_actionlint() {
	local workflows="$1"
	local workflow result

	if ! command -v actionlint &>/dev/null; then
		echo 'Warning: actionlint not installed, skipping workflow checks' >&2
		return
	fi

	while IFS= read -r workflow; do
		if [[ -f "$workflow" ]]; then
			result=$(actionlint "$workflow" 2>&1) || true
			if [[ -n "$result" ]]; then
				errors+="actionlint issues in $workflow:"$'\n'"$result"$'\n\n'
			fi
		fi
	done <<< "$workflows"
}

# Find modified shell scripts
changed_scripts=$(git diff --name-only main...HEAD 2>/dev/null | grep -E '\.sh$') || true
if [[ -n "$changed_scripts" ]]; then
	check_shellcheck "$changed_scripts"
fi

# Find modified workflow files
changed_workflows=$(git diff --name-only main...HEAD 2>/dev/null \
	| grep -E '\.github/workflows/.*\.ya?ml$') || true
if [[ -n "$changed_workflows" ]]; then
	check_actionlint "$changed_workflows"
fi

# If errors found, block the push
if [[ -n "$errors" ]]; then
	printf '%s\n' 'Lint checks failed. Fix these issues before pushing:' >&2
	printf '\n%s' "$errors" >&2
	exit 2
fi

# Report success
scripts_checked=0
workflows_checked=0
[[ -n "$changed_scripts" ]] && scripts_checked=$(printf '%s\n' "$changed_scripts" | wc -l)
[[ -n "$changed_workflows" ]] && workflows_checked=$(printf '%s\n' "$changed_workflows" | wc -l)

printf 'Pre-PR lint check passed: %d shell scripts, %d workflows checked\n' \
	"$scripts_checked" "$workflows_checked"

exit 0
