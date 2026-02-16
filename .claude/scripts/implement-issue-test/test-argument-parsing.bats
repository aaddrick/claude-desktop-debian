#!/usr/bin/env bats
#
# test-argument-parsing.bats
# Tests for implement-issue-orchestrator.sh argument parsing
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env
    # Create minimal schema so the script can start
    echo '{}' > "$TEST_TMP/schemas/implement-issue-setup.json"
}

teardown() {
    teardown_test_env
}

# =============================================================================
# REQUIRED ARGUMENTS
# =============================================================================

@test "fails without any arguments" {
    run bash "$ORCHESTRATOR_SCRIPT" 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--issue and --branch are required"* ]]
}

@test "fails with only --issue" {
    run bash "$ORCHESTRATOR_SCRIPT" --issue 123 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--issue and --branch are required"* ]]
}

@test "fails with only --branch" {
    run bash "$ORCHESTRATOR_SCRIPT" --branch test 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--issue and --branch are required"* ]]
}

@test "fails with --issue but no value" {
    run bash "$ORCHESTRATOR_SCRIPT" --issue 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--issue requires a value"* ]]
}

@test "fails with --branch but no value" {
    run bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--branch requires a value"* ]]
}

# =============================================================================
# OPTIONAL ARGUMENTS
# =============================================================================

@test "accepts --agent option" {
    # We can't run the full script, but we can verify it parses args correctly
    # by checking the output header. Timeout is expected (exit 124) since script
    # will hang waiting for external commands after printing header.
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test --agent bash-script-craftsman 2>&1
    [[ "$status" -eq 0 || "$status" -eq 124 ]] || fail "Unexpected exit status: $status"
    [[ "$output" == *"Agent: bash-script-craftsman"* ]]
}

@test "fails with --agent but no value" {
    run bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test --agent 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--agent requires a value"* ]]
}

@test "accepts --status-file option" {
    # Timeout is expected (exit 124) since script will hang after printing header
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test --status-file custom-status.json 2>&1
    [[ "$status" -eq 0 || "$status" -eq 124 ]] || fail "Unexpected exit status: $status"
    [[ "$output" == *"Status file: custom-status.json"* ]]
}

@test "fails with --status-file but no value" {
    run bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test --status-file 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--status-file requires a value"* ]]
}

# =============================================================================
# HELP
# =============================================================================

@test "--help shows usage" {
    run bash "$ORCHESTRATOR_SCRIPT" --help 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"--issue"* ]]
    [[ "$output" == *"--branch"* ]]
}

@test "-h shows usage" {
    run bash "$ORCHESTRATOR_SCRIPT" -h 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"Usage:"* ]]
}

# =============================================================================
# UNKNOWN OPTIONS
# =============================================================================

@test "fails with unknown option" {
    run bash "$ORCHESTRATOR_SCRIPT" --unknown 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"Unknown option: --unknown"* ]]
}

# =============================================================================
# VALID INVOCATION OUTPUT
# =============================================================================

@test "prints issue number in header" {
    # Timeout is expected (exit 124) since script will hang after printing header
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" --issue 456 --branch main 2>&1
    [[ "$status" -eq 0 || "$status" -eq 124 ]] || fail "Unexpected exit status: $status"
    [[ "$output" == *"Issue: #456"* ]]
}

@test "prints branch name in header" {
    # Timeout is expected (exit 124) since script will hang after printing header
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch feature-branch 2>&1
    [[ "$status" -eq 0 || "$status" -eq 124 ]] || fail "Unexpected exit status: $status"
    [[ "$output" == *"Branch: feature-branch"* ]]
}

@test "defaults agent to 'default' when not specified" {
    # Timeout is expected (exit 124) since script will hang after printing header
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test 2>&1
    [[ "$status" -eq 0 || "$status" -eq 124 ]] || fail "Unexpected exit status: $status"
    [[ "$output" == *"Agent: default"* ]]
}

@test "defaults status file to status.json" {
    # Timeout is expected (exit 124) since script will hang after printing header
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test 2>&1
    [[ "$status" -eq 0 || "$status" -eq 124 ]] || fail "Unexpected exit status: $status"
    [[ "$output" == *"Status file: status.json"* ]]
}
