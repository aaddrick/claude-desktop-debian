#!/usr/bin/env bats
#
# test-comment-helpers.bats
# Tests for the comment_issue and comment_pr helper functions
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

    mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"

    # Source the orchestrator functions
    source_orchestrator_functions
}

teardown() {
    teardown_test_env
}

# =============================================================================
# FUNCTION DEFINITIONS
# =============================================================================

@test "comment_issue function is defined" {
    [ "$(type -t comment_issue)" = "function" ]
}

@test "comment_pr function is defined" {
    [ "$(type -t comment_pr)" = "function" ]
}

# =============================================================================
# REPO CONSTANT
# =============================================================================

@test "REPO constant is defined" {
    [ -n "$REPO" ]
}

@test "REPO points to correct repository" {
    [ "$REPO" = "aaddrick/claude-desktop-debian" ]
}

# =============================================================================
# COMMENT_ISSUE STRUCTURE
# =============================================================================

@test "comment_issue uses gh issue comment" {
    local func_def
    func_def=$(declare -f comment_issue)

    [[ "$func_def" == *"gh issue comment"* ]]
}

@test "comment_issue uses ISSUE_NUMBER variable" {
    local func_def
    func_def=$(declare -f comment_issue)

    [[ "$func_def" == *'$ISSUE_NUMBER'* ]] || [[ "$func_def" == *'"$ISSUE_NUMBER"'* ]]
}

@test "comment_issue uses REPO variable" {
    local func_def
    func_def=$(declare -f comment_issue)

    [[ "$func_def" == *'$REPO'* ]] || [[ "$func_def" == *'"$REPO"'* ]]
}

@test "comment_issue includes orchestrator attribution" {
    local func_def
    func_def=$(declare -f comment_issue)

    [[ "$func_def" == *"implement-issue-orchestrator"* ]]
}

@test "comment_issue logs the action" {
    local func_def
    func_def=$(declare -f comment_issue)

    [[ "$func_def" == *"log"* ]]
}

# =============================================================================
# COMMENT_PR STRUCTURE
# =============================================================================

@test "comment_pr uses gh pr comment" {
    local func_def
    func_def=$(declare -f comment_pr)

    [[ "$func_def" == *"gh pr comment"* ]]
}

@test "comment_pr takes pr_num as first argument" {
    local func_def
    func_def=$(declare -f comment_pr)

    # Check that function uses first parameter for PR number
    [[ "$func_def" == *'pr_num="$1"'* ]] || [[ "$func_def" == *'local pr_num'* ]]
}

@test "comment_pr uses REPO variable" {
    local func_def
    func_def=$(declare -f comment_pr)

    [[ "$func_def" == *'$REPO'* ]] || [[ "$func_def" == *'"$REPO"'* ]]
}

@test "comment_pr includes orchestrator attribution" {
    local func_def
    func_def=$(declare -f comment_pr)

    [[ "$func_def" == *"implement-issue-orchestrator"* ]]
}

@test "comment_pr logs the action" {
    local func_def
    func_def=$(declare -f comment_pr)

    [[ "$func_def" == *"log"* ]]
}

# =============================================================================
# BEHAVIORAL TESTS
# =============================================================================

@test "comment_issue calls gh with correct arguments" {
    # Track gh calls
    local gh_calls="$TEST_TMP/gh-calls.txt"
    cat > "$TEST_TMP/bin/gh" << EOF
#!/usr/bin/env bash
echo "\$@" >> "$gh_calls"
exit 0
EOF
    chmod +x "$TEST_TMP/bin/gh"

    comment_issue "Test Title" "Test body content"

    [ -f "$gh_calls" ] || fail "gh was not called"
    grep -q "issue" "$gh_calls" || fail "Expected 'issue' in gh call"
    grep -q "comment" "$gh_calls" || fail "Expected 'comment' in gh call"
    grep -q "$ISSUE_NUMBER" "$gh_calls" || fail "Expected issue number in gh call"
}

@test "comment_pr calls gh with correct arguments" {
    # Track gh calls
    local gh_calls="$TEST_TMP/gh-calls.txt"
    cat > "$TEST_TMP/bin/gh" << EOF
#!/usr/bin/env bash
echo "\$@" >> "$gh_calls"
exit 0
EOF
    chmod +x "$TEST_TMP/bin/gh"

    comment_pr 456 "Test Title" "Test body content"

    [ -f "$gh_calls" ] || fail "gh was not called"
    grep -q "pr" "$gh_calls" || fail "Expected 'pr' in gh call"
    grep -q "comment" "$gh_calls" || fail "Expected 'comment' in gh call"
    grep -q "456" "$gh_calls" || fail "Expected PR number in gh call"
}

@test "comment_issue handles gh failure gracefully" {
    # Make gh fail
    cat > "$TEST_TMP/bin/gh" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$TEST_TMP/bin/gh"

    # Should not crash the script
    run comment_issue "Test Title" "Test body"

    # Should not fail (function handles error)
    [ "$status" -eq 0 ]
}

@test "comment_pr handles gh failure gracefully" {
    # Make gh fail
    cat > "$TEST_TMP/bin/gh" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$TEST_TMP/bin/gh"

    # Should not crash the script
    run comment_pr 456 "Test Title" "Test body"

    # Should not fail (function handles error)
    [ "$status" -eq 0 ]
}

@test "comment_issue writes to log file" {
    # Mock gh to succeed
    cat > "$TEST_TMP/bin/gh" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$TEST_TMP/bin/gh"

    comment_issue "Test Title" "Test body" 2>/dev/null

    # Check log file
    [ -f "$LOG_FILE" ] || fail "Log file should exist"
    grep -q "Commenting on issue" "$LOG_FILE" || fail "Expected log entry for comment"
}

@test "comment_pr writes to log file" {
    # Mock gh to succeed
    cat > "$TEST_TMP/bin/gh" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$TEST_TMP/bin/gh"

    comment_pr 456 "Test Title" "Test body" 2>/dev/null

    # Check log file
    [ -f "$LOG_FILE" ] || fail "Log file should exist"
    grep -q "Commenting on PR" "$LOG_FILE" || fail "Expected log entry for PR comment"
}

# =============================================================================
# COMMENT FORMAT TESTS
# =============================================================================

@test "comment_issue formats title as header" {
    local func_def
    func_def=$(declare -f comment_issue)

    # Should use ## for header
    [[ "$func_def" == *'## $title'* ]] || [[ "$func_def" == *"## \$title"* ]]
}

@test "comment_pr formats title as header" {
    local func_def
    func_def=$(declare -f comment_pr)

    # Should use ## for header
    [[ "$func_def" == *'## $title'* ]] || [[ "$func_def" == *"## \$title"* ]]
}

# =============================================================================
# USAGE IN MAIN FLOW
# =============================================================================

@test "main flow calls comment_issue at start" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'comment_issue "Starting Automated Processing"'* ]]
}

@test "main flow calls comment_issue after evaluation" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'comment_issue "Evaluation'* ]]
}

@test "main flow calls comment_issue for implementation plan" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'comment_issue "Implementation Plan"'* ]]
}

@test "main flow calls comment_issue for task list" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'comment_issue "Task List"'* ]]
}

@test "main flow calls comment_pr for completion" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'comment_pr "$pr_number" "Implementation Complete"'* ]]
}

@test "quality loop calls comment_issue" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    [[ "$func_def" == *"comment_issue"* ]]
}
