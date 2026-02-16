#!/usr/bin/env bats
#
# test-integration.bats
# Integration tests for the full orchestrator flow
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

    # Copy real schemas if available
    if [[ -d "$SCRIPT_DIR/schemas" ]]; then
        cp -r "$SCRIPT_DIR/schemas/"* "$SCHEMA_DIR/" 2>/dev/null || true
    fi

    # Create minimal schemas if not copied
    for schema in implement-issue-setup implement-issue-research implement-issue-evaluate \
                  implement-issue-plan implement-issue-implement implement-issue-test \
                  implement-issue-review implement-issue-fix implement-issue-task-review \
                  implement-issue-pr implement-issue-complete implement-issue-simplify; do
        if [[ ! -f "$SCHEMA_DIR/${schema}.json" ]]; then
            echo '{"type":"object"}' > "$SCHEMA_DIR/${schema}.json"
        fi
    done

    # Source the orchestrator functions
    source_orchestrator_functions
}

teardown() {
    teardown_test_env
}

# =============================================================================
# FULL WORKFLOW STRUCTURE
# =============================================================================

@test "orchestrator has all required stages" {
    local main_def
    main_def=$(declare -f main)

    # Check for all stages via set_stage_started calls
    [[ "$main_def" == *'set_stage_started "setup"'* ]]
    [[ "$main_def" == *'set_stage_started "research"'* ]]
    [[ "$main_def" == *'set_stage_started "evaluate"'* ]]
    [[ "$main_def" == *'set_stage_started "plan"'* ]]
    [[ "$main_def" == *'set_stage_started "implement"'* ]]
    [[ "$main_def" == *'set_stage_started "quality_loop"'* ]]
    [[ "$main_def" == *'set_stage_started "docs"'* ]]
    [[ "$main_def" == *'set_stage_started "pr"'* ]]
    [[ "$main_def" == *'set_stage_started "pr_review"'* ]]
    [[ "$main_def" == *'set_stage_started "complete"'* ]]
}

@test "orchestrator uses correct schema for setup" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"implement-issue-setup.json"* ]]
}

@test "orchestrator uses correct schema for implementation" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"implement-issue-implement.json"* ]]
}

@test "orchestrator uses correct schema for PR" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"implement-issue-pr.json"* ]]
}

@test "orchestrator uses correct schema for research" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"implement-issue-research.json"* ]]
}

@test "orchestrator uses correct schema for evaluate" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"implement-issue-evaluate.json"* ]]
}

@test "orchestrator uses correct schema for plan" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"implement-issue-plan.json"* ]]
}

# =============================================================================
# SETUP STAGE FLOW
# =============================================================================

@test "setup stage extracts worktree from output" {
    local main_def
    main_def=$(declare -f main)

    # Uses printf to safely handle JSON with leading hyphens/special chars
    [[ "$main_def" == *'worktree=$(printf'* ]] || [[ "$main_def" == *'worktree=$('*'setup_result'* ]]
}

@test "setup stage extracts branch from output" {
    local main_def
    main_def=$(declare -f main)

    # Uses printf to safely handle JSON with leading hyphens/special chars
    [[ "$main_def" == *'branch=$(printf'* ]] || [[ "$main_def" == *'branch=$('*'setup_result'* ]]
}

@test "plan stage extracts tasks from output" {
    local main_def
    main_def=$(declare -f main)

    # Uses printf to safely handle JSON with leading hyphens/special chars
    [[ "$main_def" == *'tasks_json=$(printf'* ]] || [[ "$main_def" == *'tasks_json=$('*'plan_result'* ]]
}

@test "setup stage saves context files" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"setup-output.json"* ]]
    [[ "$main_def" == *"tasks.json"* ]]
}

@test "plan stage saves context files" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"plan-output.json"* ]]
}

# =============================================================================
# IMPLEMENTATION LOOP
# =============================================================================

@test "implementation stage loops through tasks" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"task_count"* ]]
    [[ "$main_def" == *'for ((i=0;'* ]]
}

@test "implementation tracks completed tasks" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"completed_tasks"* ]]
}

@test "implementation respects MAX_TASK_REVIEW_ATTEMPTS" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"MAX_TASK_REVIEW_ATTEMPTS"* ]]
}

@test "implementation comments on issue after task completion" {
    local main_def
    main_def=$(declare -f main)

    # Uses comment_issue helper function
    [[ "$main_def" == *"comment_issue"* ]]
}

# =============================================================================
# PR REVIEW LOOP
# =============================================================================

@test "PR review uses spec-reviewer agent" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"spec-reviewer"* ]]
}

@test "PR review uses code-reviewer agent" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"code-reviewer"* ]]
}

@test "PR review respects MAX_PR_REVIEW_ITERATIONS" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"MAX_PR_REVIEW_ITERATIONS"* ]]
}

@test "PR review re-runs quality loop after fixes" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"run_quality_loop"* ]]
    [[ "$main_def" == *"pr-fix"* ]]
}

# =============================================================================
# COMPLETION STAGE
# =============================================================================

@test "completion stage sets final state" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'set_final_state "completed"'* ]]
}

@test "completion stage copies status to log dir" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'cp "$STATUS_FILE" "$LOG_BASE/status.json"'* ]]
}

@test "completion stage exits with 0" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"exit 0"* ]]
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

@test "orchestrator exits 1 on setup failure" {
    local main_def
    main_def=$(declare -f main)

    # Verify main checks setup_status and exits on failure
    # Use flexible pattern that matches various quote/comparison styles
    [[ "$main_def" == *"setup_status"* ]] || fail "main should check setup_status"
    [[ "$main_def" == *"success"* ]] || fail "main should compare against 'success'"
    [[ "$main_def" == *"exit 1"* ]] || fail "main should exit 1 on failure"
}

@test "orchestrator exits 1 on PR creation failure" {
    local main_def
    main_def=$(declare -f main)

    # Verify main checks pr_status for failure handling
    [[ "$main_def" == *"pr_status"* ]] || fail "main should check pr_status"
    [[ "$main_def" == *"success"* ]] || fail "main should compare against 'success'"
}

@test "orchestrator exits 2 on max quality iterations" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    [[ "$func_def" == *"exit 2"* ]]
}

# =============================================================================
# LOGGING
# =============================================================================

@test "orchestrator creates log directory structure" {
    # After init, check expected directories
    init_status

    [ -d "$LOG_BASE/stages" ]
    [ -d "$LOG_BASE/context" ]
}

@test "orchestrator writes to orchestrator.log" {
    init_status
    log "Test log entry"

    [ -f "$LOG_FILE" ]
    grep -q "Test log entry" "$LOG_FILE"
}

# =============================================================================
# GIT OPERATIONS
# =============================================================================

@test "orchestrator pushes after PR review fixes" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"git -C"* ]]
    [[ "$main_def" == *"push origin"* ]]
}

# =============================================================================
# AGENT SELECTION
# =============================================================================

@test "orchestrator uses bash-script-craftsman for fixes" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"bash-script-craftsman"* ]]
}

@test "orchestrator uses cdd-code-simplifier in quality loop" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    [[ "$func_def" == *"cdd-code-simplifier"* ]]
}

@test "orchestrator uses bats-test-validator for tests" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    [[ "$func_def" == *"bats-test-validator"* ]]
}

@test "orchestrator uses bash-script-craftsman for docs" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"bash-script-craftsman"* ]]
}

# =============================================================================
# BEHAVIORAL TESTS - TASK FAILURE HANDLING
# =============================================================================

@test "task failure updates status correctly" {
    init_status

    # Set up tasks - update_task matches on .id field, not array index
    local tasks='[{"id":1,"title":"Task 1"},{"id":2,"title":"Task 2"}]'
    set_tasks "$tasks"

    # Simulate task failure (use task id, not array index)
    update_task 1 "failed" 3

    # Verify task status
    local task_status
    task_status=$(jq -r '.tasks[0].status' "$STATUS_FILE")
    [ "$task_status" = "failed" ]

    # Verify review attempts tracked
    local review_attempts
    review_attempts=$(jq -r '.tasks[0].review_attempts' "$STATUS_FILE")
    [ "$review_attempts" = "3" ]
}

@test "failed task does not block subsequent tasks" {
    init_status

    # Set up multiple tasks with numeric IDs
    local tasks='[{"id":1,"title":"Task 1"},{"id":2,"title":"Task 2"}]'
    set_tasks "$tasks"

    # Mark first task as failed, second as completed (by task id)
    update_task 1 "failed" 3
    update_task 2 "completed" 1

    # Verify both statuses are tracked independently
    local task1_status task2_status
    task1_status=$(jq -r '.tasks[0].status' "$STATUS_FILE")
    task2_status=$(jq -r '.tasks[1].status' "$STATUS_FILE")

    [ "$task1_status" = "failed" ]
    [ "$task2_status" = "completed" ]
}

@test "max task review attempts triggers failure" {
    init_status

    local tasks='[{"id":1,"title":"Task 1"}]'
    set_tasks "$tasks"

    # Simulate hitting max review attempts (use task id)
    local attempt
    for attempt in 1 2 3; do
        update_task 1 "in_progress" "$attempt"
    done

    # After MAX_TASK_REVIEW_ATTEMPTS, task should be marked appropriately
    local review_attempts
    review_attempts=$(jq -r '.tasks[0].review_attempts' "$STATUS_FILE")
    [ "$review_attempts" = "3" ]
    [ "$review_attempts" -eq "$MAX_TASK_REVIEW_ATTEMPTS" ]
}

# =============================================================================
# BEHAVIORAL TESTS - PR REVIEW MAX ITERATIONS
# =============================================================================

@test "PR review iteration counter increments correctly" {
    init_status

    # Increment PR review iterations
    increment_pr_review_iteration
    increment_pr_review_iteration

    local iterations
    iterations=$(jq -r '.pr_review_iterations' "$STATUS_FILE")
    [ "$iterations" = "2" ]
}

@test "PR review tracks iteration in stage data" {
    init_status

    set_stage_started "pr_review"
    increment_pr_review_iteration
    increment_pr_review_iteration

    local stage_iteration
    stage_iteration=$(jq -r '.stages.pr_review.iteration' "$STATUS_FILE")
    [ "$stage_iteration" = "2" ]
}

@test "PR review max iterations sets correct exit state" {
    init_status

    # Simulate reaching max iterations
    local i
    for i in $(seq 1 "$MAX_PR_REVIEW_ITERATIONS"); do
        increment_pr_review_iteration
    done

    # Set final state for max iterations
    set_final_state "max_iterations_pr_review"

    local state
    state=$(jq -r '.state' "$STATUS_FILE")
    [ "$state" = "max_iterations_pr_review" ]
}

# =============================================================================
# BEHAVIORAL TESTS - END-TO-END MOCK FLOW
# =============================================================================

@test "complete workflow updates all stage statuses" {
    init_status

    # Simulate full workflow by updating stages in order (including new stages)
    local stages=("setup" "research" "evaluate" "plan" "implement" "quality_loop" "docs" "pr" "pr_review" "complete")

    for stage in "${stages[@]}"; do
        set_stage_started "$stage"
        set_stage_completed "$stage"
    done

    # Verify all stages completed
    local stage
    for stage in "${stages[@]}"; do
        local stage_status
        stage_status=$(jq -r ".stages.${stage}.status" "$STATUS_FILE")
        [ "$stage_status" = "completed" ] || fail "Stage $stage should be completed, got: $stage_status"
    done
}

@test "workflow tracks timing for each stage" {
    init_status

    set_stage_started "setup"
    # Small delay to ensure timestamps differ
    sleep 0.1
    set_stage_completed "setup"

    local started_at completed_at
    started_at=$(jq -r '.stages.setup.started_at' "$STATUS_FILE")
    completed_at=$(jq -r '.stages.setup.completed_at' "$STATUS_FILE")

    [ -n "$started_at" ] && [ "$started_at" != "null" ]
    [ -n "$completed_at" ] && [ "$completed_at" != "null" ]
}

# =============================================================================
# COMMENT HELPER FUNCTIONS
# =============================================================================

@test "comment_issue function is defined" {
    [ "$(type -t comment_issue)" = "function" ]
}

@test "comment_pr function is defined" {
    [ "$(type -t comment_pr)" = "function" ]
}

@test "REPO constant is defined" {
    [ -n "$REPO" ]
    [ "$REPO" = "aaddrick/claude-desktop-debian" ]
}

@test "comment_issue uses gh issue comment" {
    local func_def
    func_def=$(declare -f comment_issue)

    [[ "$func_def" == *"gh issue comment"* ]]
}

@test "comment_pr uses gh pr comment" {
    local func_def
    func_def=$(declare -f comment_pr)

    [[ "$func_def" == *"gh pr comment"* ]]
}

@test "PR review loop uses comment_pr" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"comment_pr"* ]]
}

@test "evaluate stage comments on issue" {
    local main_def
    main_def=$(declare -f main)

    # Check for comment after evaluate stage
    [[ "$main_def" == *'comment_issue "Evaluation'* ]] || [[ "$main_def" == *'comment_issue "Eval'* ]]
}

@test "plan stage comments implementation plan on issue" {
    local main_def
    main_def=$(declare -f main)

    # Check for plan comment
    [[ "$main_def" == *'comment_issue "Implementation Plan"'* ]]
}

@test "plan stage comments task list on issue" {
    local main_def
    main_def=$(declare -f main)

    # Check for task list comment
    [[ "$main_def" == *'comment_issue "Task List"'* ]]
}

@test "complete stage comments on PR" {
    local main_def
    main_def=$(declare -f main)

    # Check for completion comment on PR
    [[ "$main_def" == *'comment_pr "$pr_number" "Implementation Complete"'* ]]
}
