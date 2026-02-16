#!/usr/bin/env bats
#
# test-rate-limit.bats
# Tests for rate limit detection and handling functions
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env

    # Set required variables
    export ISSUE_NUMBER=123
    export BASE_BRANCH=test
    export STATUS_FILE="$TEST_TMP/status.json"
    export LOG_BASE="$TEST_TMP/logs/test"
    export LOG_FILE="$LOG_BASE/orchestrator.log"
    export STAGE_COUNTER=0

    mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"

    # Source the orchestrator functions
    source_orchestrator_functions
}

teardown() {
    teardown_test_env
}

# =============================================================================
# DETECT_RATE_LIMIT - STRUCTURED OUTPUT
# =============================================================================

@test "detect_rate_limit returns true for rate_limit status" {
    local output='{"result":"error","structured_output":{"status":"rate_limit"}}'
    run detect_rate_limit "$output"
    [ "$status" -eq 0 ]  # 0 = true (rate limit detected)
}

@test "detect_rate_limit returns false for success status" {
    local output='{"result":"ok","structured_output":{"status":"success"}}'
    run detect_rate_limit "$output"
    [ "$status" -eq 1 ]  # 1 = false (no rate limit)
}

# =============================================================================
# DETECT_RATE_LIMIT - TEXT PATTERNS
# =============================================================================

@test "detect_rate_limit finds 'rate limit' in result" {
    local output='{"result":"Rate limit exceeded. Please try again later."}'
    run detect_rate_limit "$output"
    [ "$status" -eq 0 ]
}

@test "detect_rate_limit finds '429' in result" {
    local output='{"result":"HTTP 429: Too Many Requests"}'
    run detect_rate_limit "$output"
    [ "$status" -eq 0 ]
}

@test "detect_rate_limit finds 'too many requests' in result" {
    local output='{"result":"Error: Too many requests to API"}'
    run detect_rate_limit "$output"
    [ "$status" -eq 0 ]
}

@test "detect_rate_limit finds 'quota exceeded' in result" {
    local output='{"result":"API quota exceeded for the day"}'
    run detect_rate_limit "$output"
    [ "$status" -eq 0 ]
}

@test "detect_rate_limit returns false for normal error" {
    local output='{"result":"File not found error"}'
    run detect_rate_limit "$output"
    [ "$status" -eq 1 ]
}

@test "detect_rate_limit returns false for normal success" {
    local output='{"result":"Task completed successfully"}'
    run detect_rate_limit "$output"
    [ "$status" -eq 1 ]
}

@test "detect_rate_limit is case insensitive" {
    local output='{"result":"RATE LIMIT hit"}'
    run detect_rate_limit "$output"
    [ "$status" -eq 0 ]
}

# =============================================================================
# EXTRACT_WAIT_TIME
# =============================================================================

@test "extract_wait_time finds retry-after header value" {
    local output='{"result":"Rate limited. Retry-After: 300 seconds"}'
    run extract_wait_time "$output"
    [ "$output" = "300" ]
}

@test "extract_wait_time finds wait X minutes pattern" {
    local output='{"result":"Please wait 15 minutes before retrying"}'
    run extract_wait_time "$output"
    [ "$output" = "900" ]  # 15 * 60
}

@test "extract_wait_time finds wait X min pattern" {
    local output='{"result":"Wait 30 min and try again"}'
    run extract_wait_time "$output"
    [ "$output" = "1800" ]  # 30 * 60
}

@test "extract_wait_time returns default when no time found" {
    local output='{"result":"Rate limit exceeded"}'
    run extract_wait_time "$output"
    [ "$output" = "3600" ]  # RATE_LIMIT_DEFAULT_WAIT
}

@test "extract_wait_time prefers retry-after over wait minutes" {
    local output='{"result":"Retry-after: 120, or wait 30 minutes"}'
    run extract_wait_time "$output"
    [ "$output" = "120" ]
}

# =============================================================================
# RATE_LIMIT_BUFFER CONSTANT
# =============================================================================

@test "RATE_LIMIT_BUFFER is defined" {
    [ -n "$RATE_LIMIT_BUFFER" ]
    [ "$RATE_LIMIT_BUFFER" -eq 60 ]
}

@test "RATE_LIMIT_DEFAULT_WAIT is defined" {
    [ -n "$RATE_LIMIT_DEFAULT_WAIT" ]
    [ "$RATE_LIMIT_DEFAULT_WAIT" -eq 3600 ]
}

# =============================================================================
# HANDLE_RATE_LIMIT (cannot fully test sleep, but test structure)
# =============================================================================

@test "handle_rate_limit logs wait time" {
    # Skip actual sleep by overriding
    sleep() { :; }
    export -f sleep

    local output='{"result":"Rate limited. Retry-After: 5 seconds"}'

    # Capture log output and verify rate limit message is logged
    local log_output
    log_output=$(handle_rate_limit "$output" 2>&1)
    [[ "$log_output" == *"Rate limit hit"* ]] || fail "Expected 'Rate limit hit' in output: $log_output"
}

# =============================================================================
# STRUCTURAL TESTS - RATE LIMIT RETRY PATH
# =============================================================================

@test "run_stage has rate limit detection" {
    # Verify run_stage includes rate limit detection logic
    local func_def
    func_def=$(declare -f run_stage)

    [[ "$func_def" == *"detect_rate_limit"* ]]
}

@test "run_stage has rate limit handling" {
    # Verify run_stage includes rate limit handling
    local func_def
    func_def=$(declare -f run_stage)

    [[ "$func_def" == *"handle_rate_limit"* ]]
}

@test "run_stage retries after rate limit handling" {
    # Verify run_stage has retry logic after rate limit
    local func_def
    func_def=$(declare -f run_stage)

    # Should have retry comment or second claude call after handle_rate_limit
    [[ "$func_def" == *"handle_rate_limit"* ]]
    [[ "$func_def" == *"Retry"* ]] || [[ "$func_def" == *"retry"* ]]
}

@test "rate limit detection integrates with handling" {
    # Test the integration: if rate limit detected, handle_rate_limit is called
    # Use a mock that simulates rate limit being detected

    # Override sleep to avoid actual wait
    sleep() { :; }
    export -f sleep

    local rate_limit_output='{"result":"Rate limit hit","structured_output":{"status":"rate_limit"}}'

    # Test detection returns true (0) for rate limited response
    run detect_rate_limit "$rate_limit_output"
    [ "$status" -eq 0 ]

    # Test handling works without error
    local log_output
    log_output=$(handle_rate_limit "$rate_limit_output" 2>&1)
    [[ "$log_output" == *"Rate limit hit"* ]] || fail "Expected rate limit log message"
}
