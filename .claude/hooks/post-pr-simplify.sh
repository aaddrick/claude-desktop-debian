#!/usr/bin/env bash
#
# PostToolUse hook: Trigger code simplifier after PR creation
#
# After a PR is successfully created, prompts Claude to run the
# cdd-code-simplifier agent against the changed files.

# Debug log setup
debug_log="$HOME/.cache/claude-desktop-debian/hook-debug.log"
mkdir -p "$(dirname "$debug_log")"

# Read JSON input from stdin - try cat as fallback
if [[ -t 0 ]]; then
	printf '\n=== %s ===\nstdin is a terminal (no input)\n' "$(date)" >> "$debug_log"
	exit 0
fi

input=$(cat)

# Debug: log received input
printf '\n=== %s ===\ninput length: %d\n%s\n' "$(date)" "${#input}" "$input" >> "$debug_log"

# Extract tool name, command, and response
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')

# Try multiple paths for the response - Bash tool response structure may vary
response=$(printf '%s' "$input" | jq -r '.tool_response // empty')
stdout=$(printf '%s' "$input" | jq -r '.tool_response.stdout // .tool_response // empty')

# Only process Bash tool calls
if [[ "$tool_name" != 'Bash' ]]; then
	exit 0
fi

# Only process gh pr create commands
if [[ "$command" != *'gh pr create'* ]]; then
	exit 0
fi

# Debug: log extracted values
printf 'tool_name=%s command=%s stdout=%s\n' "$tool_name" "$command" "$stdout" >> "$debug_log"

# Check if the PR was created successfully (look for PR URL in output)
if [[ "$stdout" != *'github.com'* ]]; then
	printf 'No github.com URL found in response, exiting\n' >> "$debug_log"
	exit 0
fi

printf 'PR URL found, triggering simplifier\n' >> "$debug_log"

# Get the list of changed files for context
changed_files=$(git diff --name-only main...HEAD 2>/dev/null | head -20)

# Build the reason message
reason="PR created successfully. Now run the cdd-code-simplifier agent to "
reason+="review and simplify the code in this PR. Focus on these changed "
reason+="files:\\n\\n${changed_files}\\n\\nRun the agent with: Use the Task "
reason+="tool with subagent_type='cdd-code-simplifier' to simplify the PR's "
reason+="changed code. After simplification, commit any changes and push to "
reason+="update the PR."

# Output JSON to prompt Claude to run the simplifier
printf '{\n  "decision": "block",\n  "reason": "%s"\n}\n' "$reason"
