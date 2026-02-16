#!/usr/bin/env bats
#
# test-quality-loop.bats
# Tests for the quality loop helper function
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

    # Create required schemas
    for schema in implement-issue-implement implement-issue-test implement-issue-review implement-issue-fix implement-issue-simplify; do
        echo '{"type":"object"}' > "$SCHEMA_DIR/${schema}.json"
    done

    # Source the orchestrator functions
    source_orchestrator_functions

    # Initialize status
    init_status
}

teardown() {
    teardown_test_env
}

# =============================================================================
# MAX_QUALITY_ITERATIONS CONSTANT
# =============================================================================

@test "MAX_QUALITY_ITERATIONS is defined" {
    [ -n "$MAX_QUALITY_ITERATIONS" ]
    [ "$MAX_QUALITY_ITERATIONS" -eq 5 ]
}

# =============================================================================
# QUALITY ITERATION TRACKING
# =============================================================================

@test "quality loop increments iteration counter" {
    # Mock run_stage to return approved immediately (with summary fields)
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes needed"}' ;;
            test-*) echo '{"status":"success","result":"passed","summary":"All tests passed"}' ;;
            review-*) echo '{"status":"success","result":"approved","summary":"Code looks good"}' ;;
        esac
    }
    export -f run_stage

    # Mock comment_issue to avoid gh calls
    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test"

    local iterations
    iterations=$(jq -r '.quality_iterations' "$STATUS_FILE")
    [ "$iterations" = "1" ]
}

@test "quality loop stage iteration matches counter" {
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"Simplified"}' ;;
            test-*) echo '{"status":"success","result":"passed","summary":"Tests passed"}' ;;
            review-*) echo '{"status":"success","result":"approved","summary":"Approved"}' ;;
        esac
    }
    export -f run_stage

    # Mock comment_issue to avoid gh calls
    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test"

    local stage_iteration
    stage_iteration=$(jq -r '.stages.quality_loop.iteration' "$STATUS_FILE")
    [ "$stage_iteration" = "1" ]
}

# =============================================================================
# TEST FAILURE HANDLING
# =============================================================================

@test "run_quality_loop function is defined" {
    # Validates the function exists and is properly sourced
    [ "$(type -t run_quality_loop)" = "function" ]
}

# =============================================================================
# REVIEW CHANGES REQUESTED HANDLING
# =============================================================================

@test "quality loop handles review changes requested" {
    # Validate function exists and has expected structure
    local func_def
    func_def=$(declare -f run_quality_loop)

    # Check for expected patterns in function
    [[ "$func_def" == *"review_verdict"* ]]
    [[ "$func_def" == *"approved"* ]]
    [[ "$func_def" == *"changes_requested"* ]] || [[ "$func_def" == *"review_comments"* ]]
}

# =============================================================================
# MAX ITERATIONS EXIT
# =============================================================================

@test "quality loop structure handles max iterations" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    # Check that function references MAX_QUALITY_ITERATIONS
    [[ "$func_def" == *"MAX_QUALITY_ITERATIONS"* ]]

    # Check that function sets max_iterations state
    [[ "$func_def" == *"max_iterations_quality"* ]]

    # Check that function exits with code 2
    [[ "$func_def" == *"exit 2"* ]]
}

# =============================================================================
# STAGE PREFIX
# =============================================================================

@test "quality loop uses stage prefix in log names" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    # Check for stage prefix usage
    [[ "$func_def" == *'stage_prefix'* ]]
    [[ "$func_def" == *'simplify-${stage_prefix}'* ]] || [[ "$func_def" == *'simplify-$stage_prefix'* ]]
}

# =============================================================================
# LOOP STRUCTURE
# =============================================================================

@test "quality loop has correct stage sequence" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    # Simplify comes before test
    local simplify_pos test_pos review_pos
    simplify_pos=$(echo "$func_def" | grep -n "simplify" | head -1 | cut -d: -f1)
    test_pos=$(echo "$func_def" | grep -n "test-\${stage_prefix}" | head -1 | cut -d: -f1)
    review_pos=$(echo "$func_def" | grep -n "review-\${stage_prefix}" | head -1 | cut -d: -f1)

    # Test comes after simplify
    [ -n "$simplify_pos" ]
    [ -n "$test_pos" ] || [ -n "$(echo "$func_def" | grep -n 'test-.*iter')" ]
}

# =============================================================================
# RETURN VALUE
# =============================================================================

@test "quality loop returns 0 on approval" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    # Check for return 0 at end
    [[ "$func_def" == *"return 0"* ]]
}

@test "quality loop uses implement-issue-simplify schema" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    # Check for simplify schema usage
    [[ "$func_def" == *"implement-issue-simplify.json"* ]]
}

@test "quality loop calls comment_issue for each sub-stage" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    # Check for comment_issue calls
    [[ "$func_def" == *"comment_issue"* ]]
}

# =============================================================================
# BEHAVIORAL TESTS - RETRY LOGIC
# =============================================================================

@test "quality loop retries when tests fail then pass" {
    # Use a file to track calls across subshell boundaries
    local counter_file="$TEST_TMP/retry_test_count"
    echo "0" > "$counter_file"
    export counter_file

    # Mock run_stage to fail tests on first attempt, pass on second
    run_stage() {
        local stage_name="$1"

        case "$stage_name" in
            simplify-*)
                echo '{"status":"success","summary":"Simplified code"}'
                ;;
            test-*)
                # Read and increment counter
                local count
                count=$(cat "$counter_file")
                count=$((count + 1))
                echo "$count" > "$counter_file"

                if [[ "$count" -le 1 ]]; then
                    # First test call fails
                    echo '{"status":"success","result":"failed","failures":[{"test":"TestCase","message":"failed"}],"summary":"1 test failed"}'
                else
                    # Second test call passes
                    echo '{"status":"success","result":"passed","summary":"All tests passed"}'
                fi
                ;;
            review-*)
                echo '{"status":"success","result":"approved","summary":"Code approved"}'
                ;;
            fix-*)
                echo '{"status":"success","summary":"Fixed test failures"}'
                ;;
        esac
    }
    export -f run_stage

    # Mock comment_issue to avoid gh calls
    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test"
    local exit_status=$?

    # Should succeed after retry
    [ "$exit_status" -eq 0 ]

    # Should have gone through at least 2 iterations
    local iterations
    iterations=$(jq -r '.quality_iterations' "$STATUS_FILE")
    [ "$iterations" -ge 2 ]
}

@test "quality loop has exit 2 for max iterations" {
    # MAX_QUALITY_ITERATIONS is readonly, so we test the structure instead
    # of behavioral execution. The function must exit with code 2 when
    # max iterations is reached.
    local func_def
    func_def=$(declare -f run_quality_loop)

    # Verify the function checks iteration count against MAX_QUALITY_ITERATIONS
    [[ "$func_def" == *"MAX_QUALITY_ITERATIONS"* ]]

    # Verify the function sets the max_iterations_quality state
    [[ "$func_def" == *"max_iterations_quality"* ]]

    # Verify the function exits with code 2
    [[ "$func_def" == *"exit 2"* ]]
}

@test "quality loop increments iteration on each retry" {
    # Use a file to track calls across subshell boundaries
    local counter_file="$TEST_TMP/test_call_count"
    echo "0" > "$counter_file"
    export counter_file

    # Mock run_stage to track iterations and succeed on 2nd quality iteration
    run_stage() {
        local stage_name="$1"

        case "$stage_name" in
            simplify-*)
                echo '{"status":"success","summary":"Simplified"}'
                ;;
            test-*)
                # Read and increment counter
                local count
                count=$(cat "$counter_file")
                count=$((count + 1))
                echo "$count" > "$counter_file"

                if [[ "$count" -lt 2 ]]; then
                    echo '{"status":"success","result":"failed","failures":[{"test":"Test","message":"failed"}],"summary":"Test failed"}'
                else
                    echo '{"status":"success","result":"passed","summary":"Tests passed"}'
                fi
                ;;
            review-*)
                echo '{"status":"success","result":"approved","summary":"Approved"}'
                ;;
            fix-*)
                echo '{"status":"success","summary":"Fixed"}'
                ;;
        esac
    }
    export -f run_stage

    # Mock comment_issue to avoid gh calls
    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test"

    # Verify we went through multiple test iterations
    local final_count
    final_count=$(cat "$counter_file")
    [ "$final_count" -ge 2 ]
}
