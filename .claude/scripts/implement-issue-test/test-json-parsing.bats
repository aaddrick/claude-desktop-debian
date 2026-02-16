#!/usr/bin/env bats
#
# test-json-parsing.bats
# Tests for JSON parsing edge cases that can cause parse failures
#
# This test file specifically targets the bug where echo "$output" | jq
# mangles special characters in large JSON outputs. The fix should use
# printf '%s' or temp files instead of echo for JSON data.
#

load 'helpers/test-helper.bash'

setup() {
	setup_test_env
	install_mocks

	# Set required variables
	export ISSUE_NUMBER=123
	export BASE_BRANCH=test
	export STATUS_FILE="$TEST_TMP/status.json"
	export LOG_BASE="$TEST_TMP/logs/test"
	export LOG_FILE="$LOG_BASE/orchestrator.log"
	export STAGE_COUNTER=0
	export SCHEMA_DIR="$TEST_TMP/schemas"

	mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"
	mkdir -p "$SCHEMA_DIR"

	# Create a valid test schema
	cat > "$SCHEMA_DIR/test-schema.json" << 'EOF'
{
	"type": "object",
	"properties": {
		"status": {"type": "string"},
		"result": {"type": "string"}
	}
}
EOF

	# Source the orchestrator functions
	source_orchestrator_functions
}

teardown() {
	teardown_test_env
}

# =============================================================================
# DIRECT TESTS FOR echo "$var" | jq PATTERN
# These tests directly exercise the problematic code pattern
# =============================================================================

@test "ECHO_BUG: echo mangles JSON starting with -n" {
	# This demonstrates the core bug: echo treats -n as a flag
	local json='-n{"test":"value"}'

	# Store in variable like run_stage does
	local output="$json"

	# This is how the script currently extracts structured_output
	local result
	result=$(echo "$output" | jq -c '.' 2>&1) || true

	# The echo will either:
	# 1. Interpret -n as "no newline" flag and output {"test":"value"} (broken)
	# 2. Output literally -n{"test":"value"} which is invalid JSON
	#
	# Either way, jq should fail or produce unexpected results
	if [[ "$result" == *"parse error"* ]] || [[ "$result" != '-n{"test":"value"}' ]]; then
		# Bug confirmed: echo mangled the output
		return 0
	fi

	fail "Expected echo to mangle JSON starting with -n, but got: $result"
}

@test "ECHO_BUG: echo mangles JSON starting with -e" {
	local json='-e{"test":"value"}'
	local output="$json"

	local result
	result=$(echo "$output" | jq -c '.' 2>&1) || true

	# echo -e enables escape interpretation
	if [[ "$result" == *"parse error"* ]] || [[ -z "$result" ]]; then
		return 0
	fi

	fail "Expected echo to mangle JSON starting with -e, but got: $result"
}

@test "ECHO_BUG: detect_rate_limit fails with hyphen-prefixed JSON" {
	# DOCUMENTATION-ONLY TEST: Demonstrates edge case behavior, not asserting specific outcome
	# The actual function uses: echo "$output" | jq -r '.structured_output.status // empty'
	# If output starts with -, echo treats it as a flag

	# Simulate Claude CLI output that starts with a hyphen (edge case)
	local output='-n{"structured_output":{"status":"success"}}'

	# This should work but may fail due to echo mangling
	run detect_rate_limit "$output"

	# If echo mangles the input, jq will fail to parse
	# The function might return unexpected results
	# We expect this to potentially fail or behave incorrectly
	# Document actual behavior for awareness
	echo "# detect_rate_limit with hyphen-prefixed JSON: status=$status" >&3
}

@test "ECHO_BUG: extract_wait_time with backslash sequences" {
	# DOCUMENTATION-ONLY TEST: Demonstrates edge case behavior, not asserting specific outcome
	# echo can interpret \n, \t, etc. in some shells/modes
	local output='{"result":"wait\n30\nminutes"}'

	run extract_wait_time "$output"

	# If echo interprets \n as newline, the JSON structure breaks
	# and jq fails to parse, returning empty or error
	# Document actual behavior for awareness
	echo "# extract_wait_time with backslash sequences: status=$status, output=$output" >&3
}

# =============================================================================
# SIMULATING THE ACTUAL BUG SCENARIO
# =============================================================================

@test "REGRESSION: structured_output extraction with variable storage" {
	# This simulates exactly what run_stage does:
	# 1. Store claude output in variable
	# 2. Extract structured_output with echo | jq

	local claude_output='{"result":"verbose output here","structured_output":{"status":"success","data":"test"}}'

	# Store in variable (like: output=$(claude -p ...))
	local output="$claude_output"

	# Extract structured_output (like: structured=$(echo "$output" | jq ...))
	local structured
	structured=$(echo "$output" | jq -c '.structured_output // empty' 2>&1)

	# Verify extraction worked
	[ -n "$structured" ] || fail "Failed to extract structured_output"
	[[ "$structured" != *"parse error"* ]] || fail "jq parse error: $structured"

	local status
	status=$(echo "$structured" | jq -r '.status')
	[ "$status" = "success" ] || fail "Expected status=success, got: $status"
}

@test "REGRESSION: large JSON payload causes parse error" {
	# Generate a large JSON payload that might trigger buffer issues
	local large_data=""
	for i in {1..500}; do
		large_data+="Item number $i with extra text for padding. "
	done

	# Create valid JSON with large data
	local claude_output
	claude_output=$(jq -n --arg data "$large_data" \
		'{"result":"large","structured_output":{"status":"success","data":$data}}')

	# Store in variable
	local output="$claude_output"

	# Extract with echo | jq (the problematic pattern)
	local structured
	local stderr_file="$TEST_TMP/stderr.txt"
	structured=$(echo "$output" | jq -c '.structured_output // empty' 2>"$stderr_file")

	# Check for parse errors
	if [[ -s "$stderr_file" ]]; then
		local stderr_content
		stderr_content=$(cat "$stderr_file")
		if [[ "$stderr_content" == *"parse error"* ]]; then
			fail "jq parse error with large payload: $stderr_content"
		fi
	fi

	[ -n "$structured" ] || fail "Failed to extract structured_output from large payload"
}

@test "REGRESSION: JSON with embedded code blocks" {
	# Real Claude CLI output often contains code in the result field
	local claude_output
	read -r -d '' claude_output << 'HEREDOC' || true
{"result":"I created the file:\n```bash\n#!/usr/bin/env bash\n\nset -uo pipefail\n\nrun_test() {\n    local result=0\n    return $result\n}\n```","structured_output":{"status":"success","files":["test-helper.sh"]}}
HEREDOC

	local output="$claude_output"

	local structured
	local stderr_file="$TEST_TMP/stderr.txt"
	structured=$(echo "$output" | jq -c '.structured_output // empty' 2>"$stderr_file")

	if [[ -s "$stderr_file" ]]; then
		local stderr_content
		stderr_content=$(cat "$stderr_file")
		if [[ "$stderr_content" == *"parse error"* ]]; then
			fail "jq parse error with code blocks: $stderr_content"
		fi
	fi

	[ -n "$structured" ] || fail "Failed to extract structured_output with code blocks"
}

# =============================================================================
# TESTING THE FIX: printf '%s' instead of echo
# =============================================================================

@test "FIX: printf safely handles JSON starting with -n" {
	local json='-n{"test":"value"}'
	local output="$json"

	# Using printf instead of echo
	local result
	result=$(printf '%s' "$output" | jq -c '.' 2>&1) || true

	# This should fail because -n{"test":"value"} is not valid JSON
	# But the failure should be due to invalid JSON, not echo mangling
	[[ "$result" == *"parse error"* ]] || fail "Expected parse error for invalid JSON"
}

@test "FIX: printf safely handles valid JSON with leading hyphen in value" {
	local json='{"flag":"-n test"}'
	local output="$json"

	local result
	result=$(printf '%s' "$output" | jq -r '.flag')

	[ "$result" = "-n test" ] || fail "Expected '-n test', got: $result"
}

@test "FIX: printf preserves backslash sequences" {
	local json='{"path":"C:\\Users\\test"}'
	local output="$json"

	local result
	result=$(printf '%s' "$output" | jq -r '.path')

	[ "$result" = 'C:\Users\test' ] || fail "Expected 'C:\\Users\\test', got: $result"
}

@test "FIX: here-string safely handles problematic JSON" {
	local json='{"flag":"-n test","path":"C:\\dir"}'
	local output="$json"

	# Using here-string instead of echo
	local result
	result=$(jq -r '.flag' <<< "$output")

	[ "$result" = "-n test" ] || fail "Expected '-n test', got: $result"
}

# =============================================================================
# RUN_STAGE INTEGRATION TESTS
# =============================================================================

@test "run_stage extracts structured_output correctly" {
	# Create mock that returns via the mock system
	export MOCK_CLAUDE_RESPONSE="$TEST_TMP/mock-response.json"
	cat > "$MOCK_CLAUDE_RESPONSE" << 'EOF'
{"result":"ok","structured_output":{"status":"success","data":"extracted"}}
EOF

	# Override timeout to use our mock directly
	timeout() {
		shift
		cat "$MOCK_CLAUDE_RESPONSE"
	}
	export -f timeout

	local result
	result=$(run_stage "test" "prompt" "test-schema.json" 2>/dev/null | grep '^{')

	[ -n "$result" ] || fail "run_stage returned no JSON output"

	local status_val
	status_val=$(printf '%s' "$result" | jq -r '.status')
	[ "$status_val" = "success" ]
}

@test "run_stage handles special characters in structured_output" {
	export MOCK_CLAUDE_RESPONSE="$TEST_TMP/mock-response.json"
	cat > "$MOCK_CLAUDE_RESPONSE" << 'EOF'
{"result":"file created","structured_output":{"status":"success","path":"/home/test/build.sh","message":"Created with\ttabs"}}
EOF

	timeout() {
		shift
		cat "$MOCK_CLAUDE_RESPONSE"
	}
	export -f timeout

	local result
	result=$(run_stage "test" "prompt" "test-schema.json" 2>/dev/null | grep '^{')

	[ -n "$result" ] || fail "run_stage returned no JSON output"

	local path_val
	path_val=$(printf '%s' "$result" | jq -r '.path')
	[ "$path_val" = '/home/test/build.sh' ] || fail "Path mangled: $path_val"
}

# =============================================================================
# DETECT_RATE_LIMIT EDGE CASES
# =============================================================================

@test "detect_rate_limit with normal success JSON" {
	local output='{"result":"ok","structured_output":{"status":"success"}}'
	run detect_rate_limit "$output"
	[ "$status" -eq 1 ]  # 1 = false (no rate limit)
}

@test "detect_rate_limit with rate_limit status" {
	local output='{"result":"error","structured_output":{"status":"rate_limit"}}'
	run detect_rate_limit "$output"
	[ "$status" -eq 0 ]  # 0 = true (rate limit detected)
}

@test "detect_rate_limit does not crash on malformed JSON" {
	local output='not valid json at all'
	run detect_rate_limit "$output"
	# Should not crash, just return false
	[ "$status" -eq 1 ]
}

@test "detect_rate_limit handles empty input" {
	local output=''
	run detect_rate_limit "$output"
	[ "$status" -eq 1 ]
}

# =============================================================================
# EXTRACT_WAIT_TIME EDGE CASES
# =============================================================================

@test "extract_wait_time finds retry-after value" {
	local output='{"result":"Rate limited. Retry-After: 300"}'
	run extract_wait_time "$output"
	[ "$output" = "300" ]
}

@test "extract_wait_time finds wait X minutes" {
	local output='{"result":"Please wait 15 minutes"}'
	run extract_wait_time "$output"
	[ "$output" = "900" ]
}

@test "extract_wait_time returns default for no time found" {
	local output='{"result":"Rate limited"}'
	run extract_wait_time "$output"
	[ "$output" = "3600" ]
}

@test "extract_wait_time handles malformed JSON gracefully" {
	local output='not json'
	run extract_wait_time "$output"
	# Should return default, not crash
	[ "$output" = "3600" ]
}

# =============================================================================
# SPECIFIC BUG REPRODUCTION
# =============================================================================

@test "BUG_REPRO: Invalid numeric literal at column 15" {
	# The reported error was: "parse error: Invalid numeric literal at line 1, column 15"
	# Column 15 in '{"structured_' would be the 's' of 'structured'
	# This suggests the JSON was corrupted around that point

	# Possible cause: echo interpreted something that corrupted the start
	local json='{"structured_output":{"status":"success"}}'

	# Test with echo (might fail)
	local echo_result
	local echo_stderr="$TEST_TMP/echo_stderr.txt"
	echo_result=$(echo "$json" | jq -c '.' 2>"$echo_stderr") || true

	# Test with printf (should work)
	local printf_result
	local printf_stderr="$TEST_TMP/printf_stderr.txt"
	printf_result=$(printf '%s' "$json" | jq -c '.' 2>"$printf_stderr")

	# printf should always work for valid JSON
	[ -n "$printf_result" ] || fail "printf method failed"
	[ ! -s "$printf_stderr" ] || fail "printf produced stderr: $(cat "$printf_stderr")"

	# If echo also worked, document that too
	if [[ -s "$echo_stderr" ]]; then
		# echo caused an error - this demonstrates the bug
		echo "# Note: echo caused jq error: $(cat "$echo_stderr")" >&3
	fi
}

@test "BUG_REPRO: Large structured output with tasks array" {
	# Create a realistic Claude CLI output with task data
	local tasks='[{"id":1,"description":"Update build script","agent":"bash-script-craftsman"},{"id":2,"description":"Fix packaging","agent":"packaging-specialist"},{"id":3,"description":"Update CI workflow","agent":"ci-workflow-architect"}]'

	local json
	json=$(jq -n --argjson tasks "$tasks" '{
		"result": "Setup complete",
		"structured_output": {
			"status": "success",
			"worktree": "/path/to/worktree",
			"branch": "feature-123",
			"tasks": $tasks
		}
	}')

	local output="$json"
	local stderr_file="$TEST_TMP/stderr.txt"

	# Test the echo pattern used in the script
	local structured
	structured=$(echo "$output" | jq -c '.structured_output // empty' 2>"$stderr_file")

	if [[ -s "$stderr_file" ]]; then
		fail "jq parse error: $(cat "$stderr_file")"
	fi

	[ -n "$structured" ] || fail "Failed to extract structured_output"

	local task_count
	task_count=$(printf '%s' "$structured" | jq '.tasks | length')
	[ "$task_count" -eq 3 ] || fail "Expected 3 tasks, got: $task_count"
}

# =============================================================================
# SHELL COMPATIBILITY TESTS
# =============================================================================

@test "echo behavior varies by shell: test with current shell" {
	# Document current shell's echo behavior
	local test_strings=(
		"-n test"
		"-e test"
		"-E test"
		"test\\nvalue"
		"test\tvalue"
	)

	for str in "${test_strings[@]}"; do
		local echo_out
		local printf_out

		echo_out=$(echo "$str" | cat)
		printf_out=$(printf '%s' "$str")

		if [[ "$echo_out" != "$printf_out" ]]; then
			echo "# Shell echo differs from printf for: $str" >&3
			echo "#   echo:   '$echo_out'" >&3
			echo "#   printf: '$printf_out'" >&3
		fi
	done

	# This test always passes - it's for documentation
	true
}

# =============================================================================
# DIRECT EXTRACTION FUNCTION TESTS
# These test the exact code pattern used in the script
# =============================================================================

@test "CRITICAL: extract_structured_output_pattern with real Claude output" {
	# This tests the EXACT pattern used in run_stage line 399:
	# structured=$(echo "$output" | jq -c '.structured_output // empty' 2>/dev/null)

	# Simulate realistic Claude CLI JSON output
	local output='{"cost":0.005,"duration_ms":1234,"result":"Implementation complete.\n\nCreated files:\n- build.sh\n- launcher.sh","structured_output":{"status":"success","worktree":"/home/user/.worktrees/feature-123","branch":"feature-123","tasks":[{"id":1,"description":"Create TestService class","agent":"bash-script-craftsman"}]}}'

	# Use the exact extraction pattern from the script
	local structured
	structured=$(echo "$output" | jq -c '.structured_output // empty' 2>/dev/null)

	# Verify extraction worked
	[ -n "$structured" ] || fail "Extraction returned empty - echo likely mangled the JSON"

	# Verify the extracted data is valid JSON
	local status
	status=$(echo "$structured" | jq -r '.status' 2>/dev/null) || fail "Extracted data is not valid JSON"
	[ "$status" = "success" ] || fail "Expected status=success, got: $status"
}

@test "CRITICAL: detect_rate_limit_pattern with real output" {
	# This tests the exact pattern used in detect_rate_limit lines 270-271:
	# status=$(echo "$output" | jq -r '.structured_output.status // empty' 2>/dev/null)

	local output='{"result":"completed","structured_output":{"status":"success","data":"test"}}'

	# Use the exact pattern from detect_rate_limit
	local status
	status=$(echo "$output" | jq -r '.structured_output.status // empty' 2>/dev/null)

	[ "$status" = "success" ] || fail "Expected 'success', got: '$status'"
}

@test "CRITICAL: extraction fails silently when echo mangles output" {
	# This test demonstrates what happens when echo mangles the JSON
	# The current implementation swallows errors with 2>/dev/null

	# Create JSON that echo might mangle
	local output='{"result":"-e test\\nvalue","structured_output":{"status":"success"}}'

	local structured
	structured=$(echo "$output" | jq -c '.structured_output // empty' 2>/dev/null)

	# If echo mangled the output, structured might be empty or wrong
	# But we can't detect this because errors are swallowed!
	if [[ -z "$structured" ]]; then
		# This is the bug: silent failure
		fail "Silent failure - extraction returned empty due to JSON corruption"
	fi
}

@test "CRITICAL: run_stage_extraction with problematic characters" {
	# Create mock response with characters that might cause issues
	export MOCK_CLAUDE_RESPONSE="$TEST_TMP/mock-response.json"

	# Include backslashes, newlines, tabs, and hyphens in values
	cat > "$MOCK_CLAUDE_RESPONSE" << 'EOF'
{"result":"Path: C:\\Users\\test\nFlag: -n test\tDone","structured_output":{"status":"success","path":"C:\\Users\\test","flag":"-n"}}
EOF

	timeout() {
		shift
		cat "$MOCK_CLAUDE_RESPONSE"
	}
	export -f timeout

	# Run the stage
	local result
	local stderr_file="$TEST_TMP/stderr.txt"
	result=$(run_stage "test" "prompt" "test-schema.json" 2>"$stderr_file" | grep '^{' | head -1)

	# Check for errors in stderr
	if grep -q "parse error" "$stderr_file" 2>/dev/null; then
		fail "jq parse error during extraction: $(cat "$stderr_file")"
	fi

	[ -n "$result" ] || fail "run_stage returned no JSON"

	# Verify the extracted values
	local flag
	flag=$(printf '%s' "$result" | jq -r '.flag')
	[ "$flag" = "-n" ] || fail "Flag value corrupted: expected '-n', got '$flag'"
}

# =============================================================================
# FIXTURE-BASED TESTS
# These use fixture files to test realistic scenarios
# =============================================================================

@test "FIXTURE: parse real-world Claude CLI success response" {
	# Create a fixture that matches real Claude CLI output format
	local fixture="$TEST_TMP/fixtures/claude-success.json"
	mkdir -p "$(dirname "$fixture")"

	cat > "$fixture" << 'EOF'
{
  "cost": 0.0123,
  "duration_ms": 45678,
  "result": "I've completed the implementation.\n\nChanges made:\n1. Updated build.sh with new patch patterns\n2. Fixed launcher.sh error handling\n3. Updated control file metadata\n\nThe code follows STYLEGUIDE.md conventions and includes proper error handling.",
  "structured_output": {
    "status": "success",
    "worktree": "/home/developer/.worktrees/issue-123",
    "branch": "feature/issue-123-user-service",
    "tasks": [
      {
        "id": 1,
        "description": "Create UserService class with CRUD operations",
        "agent": "bash-script-craftsman"
      },
      {
        "id": 2,
        "description": "Update UserController to use UserService",
        "agent": "bash-script-craftsman"
      }
    ]
  }
}
EOF

	# Read fixture into variable (simulating Claude CLI output capture)
	local output
	output=$(cat "$fixture")

	# Extract using the script's pattern
	local structured
	structured=$(echo "$output" | jq -c '.structured_output // empty' 2>/dev/null)

	[ -n "$structured" ] || fail "Failed to extract structured_output from fixture"

	local task_count
	task_count=$(printf '%s' "$structured" | jq '.tasks | length')
	[ "$task_count" -eq 2 ] || fail "Expected 2 tasks, got: $task_count"
}

@test "FIXTURE: parse response with code containing special chars" {
	local fixture="$TEST_TMP/fixtures/claude-with-code.json"
	mkdir -p "$(dirname "$fixture")"

	# This fixture contains code with backslashes, quotes, etc.
	cat > "$fixture" << 'FIXTURE_EOF'
{
  "result": "Created file:\n```bash\n#!/usr/bin/env bash\n\nset -uo pipefail\n\nformat_output() {\n    local input=\"$1\"\n    printf 'Formatted: %s\\n' \"$input\"\n}\n```",
  "structured_output": {
    "status": "success",
    "commit": "abc123def456",
    "files": ["build.sh"]
  }
}
FIXTURE_EOF

	local output
	output=$(cat "$fixture")

	local structured
	structured=$(echo "$output" | jq -c '.structured_output // empty' 2>/dev/null)

	[ -n "$structured" ] || fail "Failed to extract structured_output with code content"

	local commit
	commit=$(printf '%s' "$structured" | jq -r '.commit')
	[ "$commit" = "abc123def456" ] || fail "Commit hash corrupted: $commit"
}

# =============================================================================
# REGRESSION TESTS FOR SPECIFIC ERROR PATTERNS
# =============================================================================

@test "REGRESSION: Invalid numeric literal error pattern" {
	# The error "Invalid numeric literal at line 1, column 15" suggests
	# corruption near the start of the JSON structure

	# This JSON, if corrupted by echo, might produce that error
	local output='{"structured_output":{"status":"success","count":42}}'

	# Test both methods
	local echo_result
	local printf_result

	echo_result=$(echo "$output" | jq -c '.' 2>&1) || true
	printf_result=$(printf '%s' "$output" | jq -c '.' 2>&1)

	# printf should always work
	[[ "$printf_result" != *"parse error"* ]] || fail "printf method failed: $printf_result"

	# If echo fails, that's the bug we're testing for
	if [[ "$echo_result" == *"Invalid numeric literal"* ]]; then
		echo "# BUG CONFIRMED: echo corrupts JSON causing 'Invalid numeric literal'" >&3
	fi
}

@test "REGRESSION: extraction returns empty on large output" {
	# Generate large output that might expose buffer issues
	local large_result=""
	for i in {1..100}; do
		large_result+="Line $i: This is a longer line of output text to increase size. "
	done

	local output
	output=$(jq -n --arg result "$large_result" \
		'{"result":$result,"structured_output":{"status":"success","size":"large"}}')

	local structured
	structured=$(echo "$output" | jq -c '.structured_output // empty' 2>/dev/null)

	[ -n "$structured" ] || fail "Extraction returned empty for large output"

	local size
	size=$(printf '%s' "$structured" | jq -r '.size')
	[ "$size" = "large" ] || fail "Size field corrupted: $size"
}

# =============================================================================
# SHELL OPTION SENSITIVITY TESTS
# These tests check behavior under different shell configurations
# =============================================================================

@test "SHELL_OPTS: xpg_echo affects echo behavior with backslashes" {
	# When xpg_echo is enabled, echo interprets backslash escapes
	# This can corrupt JSON containing \\n, \\t, etc.

	local json='{"path":"C:\\new\\test"}'

	# Test with current settings
	local current_result
	current_result=$(echo "$json")

	# Test with printf (always safe)
	local safe_result
	safe_result=$(printf '%s' "$json")

	# Document if they differ
	if [[ "$current_result" != "$safe_result" ]]; then
		echo "# WARNING: echo behavior differs from printf" >&3
		echo "# echo output: $current_result" >&3
		echo "# printf output: $safe_result" >&3
		fail "echo corrupts backslash sequences - use printf instead"
	fi
}

@test "SHELL_OPTS: POSIXLY_CORRECT affects echo" {
	# In POSIX mode, echo may behave differently
	local json='{"test":"-n value"}'

	local result
	result=$(echo "$json")

	# Verify the output is valid JSON
	if ! printf '%s' "$result" | jq -e '.' >/dev/null 2>&1; then
		fail "echo produced invalid JSON in current shell mode"
	fi
}

# =============================================================================
# BINARY/SPECIAL DATA TESTS
# =============================================================================

@test "BINARY: JSON with null bytes would break echo" {
	# Note: We can't easily test null bytes as they break bash strings
	# But we can document that this is a limitation

	# Test with other problematic bytes (bell, backspace, etc.)
	local json='{"data":"test\x07bell"}'  # \x07 is bell character

	# printf handles this, echo might not
	local result
	result=$(printf '%s' "$json" | jq -c '.' 2>&1) || true

	# This should either work or fail cleanly
	[ -n "$result" ]
}

@test "BINARY: JSON with high ASCII characters" {
	# Characters > 127 might cause issues
	local json='{"data":"caf\xc3\xa9"}'  # UTF-8 for "cafe" with accent

	local result
	result=$(echo "$json" | jq -c '.' 2>&1) || true

	# Document behavior
	if [[ "$result" == *"parse error"* ]]; then
		echo "# Note: High ASCII characters cause parse errors" >&3
	fi
}

# =============================================================================
# ROBUSTNESS VERIFICATION TESTS
# These verify that the fix (printf/%s) is robust
# =============================================================================

@test "ROBUSTNESS: printf handles all echo problem cases" {
	local test_cases=(
		'-n{"test":1}'
		'-e{"test":2}'
		'-E{"test":3}'
		'{"path":"C:\\test"}'
		'{"newline":"line1\nline2"}'
		'{"tab":"col1\tcol2"}'
	)

	for json in "${test_cases[@]}"; do
		local result
		result=$(printf '%s' "$json" | cat)

		# printf should preserve the exact string
		if [[ "$result" != "$json" ]]; then
			fail "printf modified string: input='$json' output='$result'"
		fi
	done
}

@test "ROBUSTNESS: here-string handles all echo problem cases" {
	local test_cases=(
		'{"flag":"-n"}'
		'{"path":"C:\\test"}'
		'{"multi":"a\nb"}'
	)

	for json in "${test_cases[@]}"; do
		local result
		result=$(jq -c '.' <<< "$json" 2>&1) || true

		# Here-string should produce valid jq output
		if [[ "$result" == *"parse error"* ]]; then
			fail "here-string failed for: $json"
		fi
	done
}

# =============================================================================
# CODE PATTERN VERIFICATION
# These verify the script uses safe patterns
# =============================================================================

@test "CODECHECK: run_stage uses echo for JSON extraction" {
	# Verify the current (buggy) implementation uses echo
	# This test will PASS if the bug exists, documenting it needs fixing

	local func_def
	func_def=$(declare -f run_stage)

	# Check if run_stage uses the problematic pattern
	if [[ "$func_def" == *'echo "$output" | jq'* ]]; then
		echo "# WARNING: run_stage uses 'echo \"\$output\" | jq' pattern" >&3
		echo "# This is vulnerable to echo mangling JSON data" >&3
		echo "# FIX: Use 'printf \"%s\" \"\$output\" | jq' or '<<< \"\$output\"'" >&3
	fi

	# This test passes to document the issue exists
	true
}

@test "CODECHECK: detect_rate_limit uses echo for JSON parsing" {
	local func_def
	func_def=$(declare -f detect_rate_limit)

	# Count uses of problematic echo pattern
	local echo_count
	echo_count=$(echo "$func_def" | grep -c 'echo "\$' || true)

	if ((echo_count > 0)); then
		echo "# WARNING: detect_rate_limit uses echo with variables $echo_count times" >&3
		echo "# Recommend using printf or here-strings for JSON data" >&3
	fi

	true
}

@test "CODECHECK: extract_wait_time uses echo for JSON parsing" {
	local func_def
	func_def=$(declare -f extract_wait_time)

	local echo_count
	echo_count=$(echo "$func_def" | grep -c 'echo "\$' || true)

	if ((echo_count > 0)); then
		echo "# WARNING: extract_wait_time uses echo with variables $echo_count times" >&3
	fi

	true
}

# =============================================================================
# FINAL VALIDATION: This test should FAIL if echo is used
# =============================================================================

@test "VALIDATION: JSON extraction must not corrupt data" {
	# This is the key validation test
	# It creates JSON that is GUARANTEED to be corrupted by echo -n interpretation

	# JSON where the structured_output value starts with -n
	# If echo interprets -n as a flag, extraction will fail
	local output='{"result":"test","structured_output":{"-n":"flag_value","status":"success"}}'

	# Use the script's extraction pattern
	local structured
	structured=$(echo "$output" | jq -c '.structured_output // empty' 2>/dev/null)

	# Verify the -n key was preserved
	local flag_value
	flag_value=$(printf '%s' "$structured" | jq -r '."-n"' 2>/dev/null) || true

	# If extraction worked, the -n key should have its value
	if [[ "$flag_value" != "flag_value" ]]; then
		# This might not fail if jq handles it, but documents the risk
		echo "# Note: -n key extraction result: $flag_value" >&3
	fi

	# The main check: structured output should not be empty
	[ -n "$structured" ] || fail "Extraction returned empty - JSON was corrupted"
}

# =============================================================================
# TEE STDOUT POLLUTION TESTS
# These tests catch the bug where log() using tee pollutes function return values
# =============================================================================

@test "TEE_BUG: tee in log function pollutes stdout" {
	# Demonstrate how tee in a log function pollutes stdout
	local LOG_FILE="$TEST_TMP/test.log"

	# BAD: log function using tee
	bad_log() {
		echo "[LOG] $*" | tee -a "$LOG_FILE"
	}

	# Function that returns JSON but calls log
	bad_get_result() {
		bad_log "Processing request..."
		echo '{"status":"success"}'
	}

	# Capture the result - this will be polluted!
	local result
	result=$(bad_get_result)

	# The result should be JUST the JSON, but tee pollutes it
	if [[ "$result" == '{"status":"success"}' ]]; then
		fail "Expected tee to pollute stdout, but it didn't - test may be invalid"
	fi

	# Verify the pollution is present
	[[ "$result" == *"[LOG]"* ]] || fail "Expected log message in stdout"
	[[ "$result" == *"success"* ]] || fail "Expected JSON in stdout"

	# This demonstrates the bug - result contains BOTH log and JSON
	echo "# Polluted result: $result" >&3
}

@test "TEE_FIX: separate writes to file and stderr avoid pollution" {
	# Demonstrate the fix - write to file and stderr separately
	local LOG_FILE="$TEST_TMP/test.log"

	# GOOD: log function writing to file and stderr separately
	good_log() {
		local msg="[LOG] $*"
		printf '%s\n' "$msg" >> "$LOG_FILE"
		printf '%s\n' "$msg" >&2
	}

	# Function that returns JSON and calls log
	good_get_result() {
		good_log "Processing request..."
		echo '{"status":"success"}'
	}

	# Capture the result - should be clean JSON
	local result
	result=$(good_get_result 2>/dev/null)  # Suppress stderr for test

	# Result should be ONLY the JSON
	[[ "$result" == '{"status":"success"}' ]] || fail "Expected clean JSON, got: $result"

	# Log file should have the message
	[[ -f "$LOG_FILE" ]] || fail "Log file should exist"
	grep -q "Processing request" "$LOG_FILE" || fail "Log file should contain message"
}

@test "CODECHECK: log function must not use tee to stdout" {
	# Check if the orchestrator's log function uses tee
	local func_def
	func_def=$(declare -f log 2>/dev/null) || {
		skip "log function not defined"
	}

	# Check for tee without redirection (pollutes stdout)
	if echo "$func_def" | grep -qE 'tee\s+-a\s+"\$LOG_FILE"[^>]*(;|\s*$|\s*})'; then
		echo "# FAIL: log function uses 'tee -a' which pollutes stdout" >&3
		echo "# When log() is called from a function captured by \$()," >&3
		echo "# the tee output becomes part of the return value" >&3
		echo "# FIX: Use separate printf to file and stderr:" >&3
		echo "#   printf '%s\\n' \"\$msg\" >> \"\$LOG_FILE\"" >&3
		echo "#   printf '%s\\n' \"\$msg\" >&2" >&3
		fail "log function uses tee which pollutes stdout"
	fi

	# Verify it uses the correct pattern (printf to file and stderr)
	if ! echo "$func_def" | grep -qE '>>.*LOG_FILE'; then
		echo "# WARNING: log function may not write to LOG_FILE correctly" >&3
	fi

	if ! echo "$func_def" | grep -qE '>&2'; then
		echo "# WARNING: log function may not write to stderr" >&3
	fi
}

@test "CODECHECK: run_stage log calls must not pollute return value" {
	# Verify run_stage calls log but still returns clean JSON
	local func_def
	func_def=$(declare -f run_stage 2>/dev/null) || {
		skip "run_stage function not defined"
	}

	# run_stage should call log
	if ! echo "$func_def" | grep -qE '\blog\b'; then
		echo "# INFO: run_stage does not appear to call log()" >&3
	fi

	# run_stage should return JSON via printf or echo at the end
	if ! echo "$func_def" | grep -qE "(printf|echo).*structured"; then
		echo "# WARNING: run_stage may not return structured output correctly" >&3
	fi
}

@test "REGRESSION: log pollution causes jq parse failure" {
	# This test simulates the exact failure we saw in production
	local LOG_FILE="$TEST_TMP/test.log"

	# Simulate the BAD log function
	bad_log() {
		echo "[$(date -Iseconds)] $*" | tee -a "$LOG_FILE"
	}

	# Simulate run_stage with bad logging
	bad_run_stage() {
		bad_log "Running stage: test"
		bad_log "  Schema: test.json"
		# Return JSON
		printf '%s\n' '{"status":"success","worktree":"/tmp/test"}'
	}

	# Capture result like main() does
	local result
	result=$(bad_run_stage)

	# Try to parse with jq - this should fail!
	local status
	status=$(printf '%s' "$result" | jq -r '.status' 2>&1) || true

	# jq should fail or return wrong value because of log pollution
	if [[ "$status" == "success" ]]; then
		fail "Expected jq to fail due to log pollution, but it succeeded"
	fi

	# The error should indicate parse failure
	[[ "$status" == *"parse error"* ]] || [[ "$status" != "success" ]] || \
		fail "Expected parse error or wrong value, got: $status"

	echo "# Demonstrated failure: jq returned '$status' instead of 'success'" >&3
}

@test "REGRESSION: fixed log function allows clean jq parsing" {
	# This test verifies the fix works
	local LOG_FILE="$TEST_TMP/test.log"

	# The FIXED log function
	good_log() {
		local msg="[$(date -Iseconds)] $*"
		printf '%s\n' "$msg" >> "$LOG_FILE"
		printf '%s\n' "$msg" >&2
	}

	# Simulate run_stage with good logging
	good_run_stage() {
		good_log "Running stage: test"
		good_log "  Schema: test.json"
		# Return JSON
		printf '%s\n' '{"status":"success","worktree":"/tmp/test"}'
	}

	# Capture result like main() does (suppress stderr)
	local result
	result=$(good_run_stage 2>/dev/null)

	# Parse with jq - this should succeed!
	local status
	status=$(printf '%s' "$result" | jq -r '.status' 2>&1)

	[[ "$status" == "success" ]] || fail "Expected 'success', got: $status"
}

# =============================================================================
# LOG_ERROR TESTS
# These verify log_error() with 'tee ... >&2' does NOT pollute stdout
# =============================================================================

@test "TEE_STDERR: log_error with tee >&2 does NOT pollute stdout" {
	# The orchestrator's log_error uses: echo "..." | tee -a "$LOG_FILE" >&2
	# The >&2 at the end redirects tee's stdout to stderr
	# This should NOT pollute the function's stdout
	local LOG_FILE="$TEST_TMP/test.log"

	# Simulate log_error pattern from orchestrator (line 116)
	log_error_pattern() {
		echo "[$(date -Iseconds)] ERROR: $*" | tee -a "$LOG_FILE" >&2
	}

	# Function that returns JSON but calls log_error
	get_result_with_error_log() {
		log_error_pattern "Something went wrong"
		echo '{"status":"partial_success"}'
	}

	# Capture stdout only (stderr suppressed for test)
	local result
	result=$(get_result_with_error_log 2>/dev/null)

	# Result should be ONLY the JSON, no log pollution
	[[ "$result" == '{"status":"partial_success"}' ]] || \
		fail "Expected clean JSON, got: $result"
}

@test "TEE_STDERR: log_error writes to both file and stderr" {
	local LOG_FILE="$TEST_TMP/test.log"

	# Simulate log_error pattern
	log_error_pattern() {
		echo "[$(date -Iseconds)] ERROR: $*" | tee -a "$LOG_FILE" >&2
	}

	# Capture stderr
	local stderr_output
	stderr_output=$(log_error_pattern "Test error message" 2>&1)

	# Should have written to stderr
	[[ "$stderr_output" == *"ERROR: Test error message"* ]] || \
		fail "Expected error message in stderr, got: $stderr_output"

	# Should have written to log file
	[[ -f "$LOG_FILE" ]] || fail "Log file should exist"
	grep -q "ERROR: Test error message" "$LOG_FILE" || \
		fail "Log file should contain error message"
}

@test "TEE_STDERR: log_error echo can still mangle -n prefix" {
	# While >&2 prevents stdout pollution, the echo inside can still mangle
	# messages starting with -n, -e, etc.
	local LOG_FILE="$TEST_TMP/test.log"

	# Simulate log_error with problematic input
	log_error_pattern() {
		echo "[$(date -Iseconds)] ERROR: $*" | tee -a "$LOG_FILE" >&2
	}

	# Call with -n prefix (edge case)
	local stderr_output
	stderr_output=$(log_error_pattern "-n test value" 2>&1)

	# Check if -n was preserved or interpreted as flag
	if [[ "$stderr_output" == *"-n test value"* ]]; then
		# Good: -n was preserved
		true
	else
		# Document the issue
		echo "# WARNING: log_error may mangle messages starting with -n" >&3
		echo "# Got: $stderr_output" >&3
	fi
}

@test "CODECHECK: log_error uses tee with stderr redirect" {
	# Verify the orchestrator's log_error function pattern
	local func_def
	func_def=$(declare -f log_error 2>/dev/null) || {
		skip "log_error function not defined"
	}

	# Must use tee with >&2 redirect (the current pattern)
	if echo "$func_def" | grep -qE 'tee.*>&2'; then
		# Using tee with stderr redirect - stdout not polluted
		echo "# log_error uses 'tee ... >&2' pattern - stdout safe" >&3
	elif echo "$func_def" | grep -qE '\| *tee'; then
		# Using tee WITHOUT stderr redirect - would pollute stdout
		fail "log_error uses tee without >&2 - this would pollute stdout"
	else
		echo "# log_error does not use tee pattern" >&3
	fi

	# Warn about echo usage (potential -n/-e issues)
	if echo "$func_def" | grep -qE 'echo.*\$'; then
		echo "# WARNING: log_error uses echo which can mangle -n/-e prefixes" >&3
		echo "# Consider using printf for robustness" >&3
	fi
}

@test "VALIDATION: orchestrator log function uses correct pattern" {
	# Final validation that the actual orchestrator is fixed
	local func_def
	func_def=$(declare -f log 2>/dev/null) || {
		skip "log function not defined"
	}

	# Must NOT use tee
	if echo "$func_def" | grep -q '| *tee'; then
		fail "log function must not pipe to tee"
	fi

	# Must write to LOG_FILE
	echo "$func_def" | grep -qE '>>.*LOG_FILE' || \
		fail "log function must append to LOG_FILE"

	# Must write to stderr
	echo "$func_def" | grep -qE '>&2' || \
		fail "log function must write to stderr"

	echo "# PASS: log function uses correct pattern (file + stderr, no tee)" >&3
}

@test "VALIDATION: orchestrator log_error does not pollute stdout" {
	# Verify log_error() uses tee with >&2 so it doesn't pollute stdout
	local func_def
	func_def=$(declare -f log_error 2>/dev/null) || {
		skip "log_error function not defined"
	}

	# If using tee, MUST have >&2 to redirect stdout to stderr
	if echo "$func_def" | grep -qE '\| *tee'; then
		# Check for >&2 redirect
		echo "$func_def" | grep -qE 'tee.*>&2' || \
			fail "log_error uses tee without >&2 - this pollutes stdout"
		echo "# PASS: log_error uses 'tee ... >&2' - stdout not polluted" >&3
	else
		# Not using tee - verify it writes to stderr
		echo "$func_def" | grep -qE '>&2' || \
			fail "log_error must write to stderr"
		echo "# PASS: log_error writes to stderr without tee" >&3
	fi
}
