#!/usr/bin/env bash
#
# PostToolUse hook: Trigger code simplifier after PR creation
#
# After a PR is successfully created, prompts Claude to run the
# cdd-code-simplifier agent against the changed files.

# Read JSON input from stdin
input=$(</dev/stdin)

# Extract tool name, command, and response
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')
command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
response=$(printf '%s' "$input" | jq -r '.tool_response.stdout // empty')

# Only process Bash tool calls
if [[ "$tool_name" != 'Bash' ]]; then
	exit 0
fi

# Only process gh pr create commands
if [[ "$command" != *'gh pr create'* ]]; then
	exit 0
fi

# Check if the PR was created successfully (look for PR URL in output)
if [[ "$response" != *'github.com'* ]]; then
	exit 0
fi

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
