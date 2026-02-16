#!/usr/bin/env bats
#
# test-stage-runner.bats
# Tests for the run_stage function
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
# SCHEMA VALIDATION
# =============================================================================

@test "run_stage fails with missing schema file" {
    run run_stage "test-stage" "test prompt" "nonexistent.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"schema not found"* ]]
}

@test "run_stage uses correct schema file" {
    # Create mock response file
    export MOCK_CLAUDE_RESPONSE="$TEST_TMP/mock-response.json"
    echo '{"result":"ok","structured_output":{"status":"success","result":"done"}}' > "$MOCK_CLAUDE_RESPONSE"

    run run_stage "test-stage" "test prompt" "test-schema.json"

    # Check that the stage log was created
    local stage_log
    stage_log=$(ls "$LOG_BASE/stages/"*.log 2>/dev/null | head -1)
    [ -n "$stage_log" ]
}

# =============================================================================
# STAGE COUNTER AND LOGGING
# =============================================================================

@test "next_stage_log increments counter" {
    # Note: next_stage_log increments STAGE_COUNTER, but when called in a
    # subshell (via command substitution), the increment is lost to the parent.
    # This tests the function's output format, not the counter persistence.
    # Each call in a subshell sees its own incremented value.
    STAGE_COUNTER=0
    local log1
    log1=$(next_stage_log "setup")
    [ "$log1" = "01-setup.log" ]

    # For sequential numbering, we'd need to call without subshell
    # or increment manually. Test direct call instead:
    STAGE_COUNTER=1
    local log2
    log2=$(next_stage_log "implement")
    [ "$log2" = "02-implement.log" ]

    STAGE_COUNTER=2
    local log3
    log3=$(next_stage_log "review")
    [ "$log3" = "03-review.log" ]
}

@test "next_stage_log pads single digits" {
    STAGE_COUNTER=8
    local log
    log=$(next_stage_log "test")
    [ "$log" = "09-test.log" ]
}

@test "next_stage_log handles double digits" {
    STAGE_COUNTER=99
    local log
    log=$(next_stage_log "test")
    [ "$log" = "100-test.log" ]
}

# =============================================================================
# LOG FUNCTIONS
# =============================================================================

@test "log writes to log file" {
    log "Test message"
    grep -q "Test message" "$LOG_FILE"
}

@test "log includes timestamp" {
    log "Test message"
    # ISO 8601 format: YYYY-MM-DDTHH:MM:SS+TZ
    grep -qE '\[[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$LOG_FILE"
}

@test "log_error writes to log file" {
    log_error "Error message" 2>/dev/null
    grep -q "ERROR: Error message" "$LOG_FILE"
}

# =============================================================================
# STRUCTURED OUTPUT EXTRACTION
# =============================================================================

@test "run_stage extracts structured_output" {
    # Create mock response file
    local mock_response="$TEST_TMP/mock-response.json"
    echo '{"result":"verbose text","structured_output":{"status":"success","data":"extracted"}}' > "$mock_response"

    # Override timeout and claude to return mock response directly
    timeout() {
        shift  # skip timeout value
        # Instead of running claude, just output mock response
        cat "$mock_response"
    }
    export -f timeout

    local result
    # run_stage outputs log lines followed by JSON on the last line
    # Extract just the JSON line (starts with '{')
    result=$(run_stage "test" "prompt" "test-schema.json" | grep '^{')
    [ -n "$result" ] || fail "run_stage returned no JSON output"

    local extracted_status
    extracted_status=$(echo "$result" | jq -r '.status')
    [ "$extracted_status" = "success" ]
}

@test "run_stage returns error for missing structured_output" {
    export MOCK_CLAUDE_RESPONSE="$TEST_TMP/mock-response.json"
    echo '{"result":"no structured output"}' > "$MOCK_CLAUDE_RESPONSE"

    run run_stage "test" "prompt" "test-schema.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no structured output"* ]]
}

# =============================================================================
# TIMEOUT HANDLING
# =============================================================================

@test "run_stage returns timeout error on exit code 124" {
    # Override timeout to simulate timeout
    timeout() {
        return 124
    }
    export -f timeout

    run run_stage "test" "prompt" "test-schema.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"timeout"* ]]
}

# =============================================================================
# AGENT SELECTION
# =============================================================================

@test "run_stage passes agent when specified" {
    export MOCK_CLAUDE_RESPONSE="$TEST_TMP/mock-response.json"
    echo '{"result":"ok","structured_output":{"status":"success"}}' > "$MOCK_CLAUDE_RESPONSE"

    # Create a tracking mock that logs to test temp dir
    local claude_calls="$TEST_TMP/claude-calls.txt"
    cat > "$TEST_TMP/bin/claude" << EOF
#!/usr/bin/env bash
echo "\$@" >> "$claude_calls"
echo '{"result":"ok","structured_output":{"status":"success"}}'
EOF
    chmod +x "$TEST_TMP/bin/claude"

    run_stage "test" "prompt" "test-schema.json" "bash-script-craftsman"

    # Verify agent was passed to claude
    [ -f "$claude_calls" ] || fail "Claude was not called"
    grep -q -- "--agent bash-script-craftsman" "$claude_calls" || \
        grep -q "bash-script-craftsman" "$claude_calls" || \
        fail "Agent 'bash-script-craftsman' was not passed to claude. Calls: $(cat "$claude_calls")"
}
