#!/usr/bin/env bats
#
# test-constants.bats
# Tests for configuration constants and defaults
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
# TIMEOUT CONSTANTS
# =============================================================================

@test "STAGE_TIMEOUT is 1 hour" {
    [ "$STAGE_TIMEOUT" -eq 3600 ]
}

# =============================================================================
# RETRY LIMITS
# =============================================================================

@test "MAX_TASK_REVIEW_ATTEMPTS is 3" {
    [ "$MAX_TASK_REVIEW_ATTEMPTS" -eq 3 ]
}

@test "MAX_QUALITY_ITERATIONS is 5" {
    [ "$MAX_QUALITY_ITERATIONS" -eq 5 ]
}

@test "MAX_PR_REVIEW_ITERATIONS is 3" {
    [ "$MAX_PR_REVIEW_ITERATIONS" -eq 3 ]
}

# =============================================================================
# RATE LIMIT CONSTANTS
# =============================================================================

@test "RATE_LIMIT_BUFFER is 60 seconds" {
    [ "$RATE_LIMIT_BUFFER" -eq 60 ]
}

@test "RATE_LIMIT_DEFAULT_WAIT is 1 hour" {
    [ "$RATE_LIMIT_DEFAULT_WAIT" -eq 3600 ]
}

# =============================================================================
# SCRIPT PATHS
# =============================================================================

@test "SCRIPT_DIR is defined" {
    [ -n "$SCRIPT_DIR" ]
}

@test "SCHEMA_DIR is under SCRIPT_DIR" {
    [[ "$SCHEMA_DIR" == "$SCRIPT_DIR"* ]] || [[ "$SCHEMA_DIR" == *"/schemas" ]]
}

# =============================================================================
# DEFAULT VALUES
# =============================================================================

@test "default STATUS_FILE is status.json" {
    # Re-source with fresh defaults
    local script_content
    script_content=$(cat "$ORCHESTRATOR_SCRIPT")

    [[ "$script_content" == *'STATUS_FILE="status.json"'* ]]
}

@test "AGENT defaults to empty string" {
    # Parse script to verify default
    local script_content
    script_content=$(cat "$ORCHESTRATOR_SCRIPT")

    [[ "$script_content" == *'AGENT=""'* ]]
}

# =============================================================================
# READONLY DECLARATIONS
# =============================================================================

@test "timeout constants are readonly" {
    local script_content
    script_content=$(cat "$ORCHESTRATOR_SCRIPT")

    [[ "$script_content" == *"readonly STAGE_TIMEOUT"* ]]
    [[ "$script_content" == *"readonly MAX_TASK_REVIEW_ATTEMPTS"* ]]
    [[ "$script_content" == *"readonly MAX_QUALITY_ITERATIONS"* ]]
    [[ "$script_content" == *"readonly MAX_PR_REVIEW_ITERATIONS"* ]]
    [[ "$script_content" == *"readonly RATE_LIMIT_BUFFER"* ]]
    [[ "$script_content" == *"readonly RATE_LIMIT_DEFAULT_WAIT"* ]]
}

# =============================================================================
# EXIT CODES
# =============================================================================

@test "usage exits with code 3" {
    run bash "$ORCHESTRATOR_SCRIPT" --help 2>&1
    [ "$status" -eq 3 ]
}

@test "script uses documented exit codes" {
    local script_content
    script_content=$(cat "$ORCHESTRATOR_SCRIPT")

    # Verify script uses the documented exit codes:
    # 0 = success, 1 = error, 2 = max iterations, 3 = usage
    [[ "$script_content" == *"exit 0"* ]]
    [[ "$script_content" == *"exit 1"* ]]
    [[ "$script_content" == *"exit 2"* ]]
    [[ "$script_content" == *"exit 3"* ]]
}

# =============================================================================
# SHELL OPTIONS
# =============================================================================

@test "script uses set -uo pipefail" {
    local script_content
    script_content=$(head -20 "$ORCHESTRATOR_SCRIPT")

    [[ "$script_content" == *"set -uo pipefail"* ]]
}

@test "script does not use set -e (handles errors explicitly)" {
    local script_content
    script_content=$(head -20 "$ORCHESTRATOR_SCRIPT")

    # Should NOT have set -e or set -euo (errexit causes unpredictable behavior)
    # The script should use explicit error handling instead
    if [[ "$script_content" == *"set -e"* ]] && [[ "$script_content" != *"set -uo pipefail"* ]]; then
        fail "Script uses 'set -e' which causes unpredictable error handling. Use explicit checks instead."
    fi
    # Verify it uses the preferred pattern: set -uo pipefail (without -e)
    [[ "$script_content" == *"set -uo pipefail"* ]] || \
        fail "Script should use 'set -uo pipefail' (without -e) for error handling"
}
