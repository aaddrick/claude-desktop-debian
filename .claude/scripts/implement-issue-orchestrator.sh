#!/usr/bin/env bash
#
# implement-issue-orchestrator.sh
# Orchestrates implement-issue workflow via Claude CLI calls per stage
#
# Usage:
#   ./implement-issue-orchestrator.sh --issue 123 --branch test
#   ./implement-issue-orchestrator.sh --issue 123 --branch test --agent patch-engineer
#
# Outputs:
#   - status.json: Real-time progress
#   - logs/implement-issue/<timestamp>/: Per-stage logs
#

set -uo pipefail  # Note: not -e, we handle errors explicitly

# Allow nested Claude CLI invocations when run from within a Claude Code session
unset CLAUDECODE

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_DIR="$SCRIPT_DIR/schemas"

# Timeouts and limits
readonly STAGE_TIMEOUT=3600  # 1 hour per stage
readonly MAX_TASK_REVIEW_ATTEMPTS=3
readonly MAX_QUALITY_ITERATIONS=5
readonly MAX_TEST_ITERATIONS=10
readonly MAX_PR_REVIEW_ITERATIONS=3
readonly RATE_LIMIT_BUFFER=60
readonly RATE_LIMIT_DEFAULT_WAIT=3600

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

ISSUE_NUMBER=""
BASE_BRANCH=""
AGENT=""
STATUS_FILE="status.json"
RESUME_MODE=""
RESUME_LOG_DIR=""

usage() {
    cat <<EOF
Usage: $0 --issue <number> --branch <name> [options]
       $0 --resume [--status-file <path>]
       $0 --resume-from <log-dir>

Options:
  --issue <number>       GitHub issue number (required for new runs)
  --branch <name>        Base branch for PR (required for new runs)
  --agent <name>         Default agent for setup stage (optional)
  --status-file <path>   Custom status file path (optional)
  --resume               Resume from existing status.json
  --resume-from <dir>    Resume from specific log directory

Resume modes:
  --resume uses the current status.json (or --status-file path)
  --resume-from reads status.json from the specified log directory

Agents are determined per-task from setup output.
EOF
    exit 3
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --issue)
            [[ -n "${2:-}" ]] || { echo "ERROR: --issue requires a value" >&2; exit 3; }
            ISSUE_NUMBER="$2"
            shift 2
            ;;
        --branch)
            [[ -n "${2:-}" ]] || { echo "ERROR: --branch requires a value" >&2; exit 3; }
            BASE_BRANCH="$2"
            shift 2
            ;;
        --agent)
            [[ -n "${2:-}" ]] || { echo "ERROR: --agent requires a value" >&2; exit 3; }
            AGENT="$2"
            shift 2
            ;;
        --status-file)
            [[ -n "${2:-}" ]] || { echo "ERROR: --status-file requires a value" >&2; exit 3; }
            STATUS_FILE="$2"
            shift 2
            ;;
        --resume)
            RESUME_MODE="status"
            shift
            ;;
        --resume-from)
            [[ -n "${2:-}" ]] || { echo "ERROR: --resume-from requires a log directory path" >&2; exit 3; }
            RESUME_MODE="logdir"
            RESUME_LOG_DIR="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate arguments based on mode
if [[ -n "$RESUME_MODE" ]]; then
    # Resume mode - issue and branch will be read from status.json
    :
elif [[ -z "$ISSUE_NUMBER" || -z "$BASE_BRANCH" ]]; then
    echo "ERROR: --issue and --branch are required (or use --resume/--resume-from)"
    usage
fi

# =============================================================================
# LOGGING FUNCTIONS (defined early so other functions can use log/log_error)
# Note: LOG_FILE and mkdir happen later after LOG_BASE is set
# =============================================================================

LOG_FILE=""
STAGE_COUNTER=0

log() {
    local msg
    msg="[$(date -Iseconds)] $*"
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s\n' "$msg" >> "$LOG_FILE"
    fi
    printf '%s\n' "$msg" >&2
}

log_error() {
    local msg
    msg="[$(date -Iseconds)] ERROR: $*"
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s\n' "$msg" >> "$LOG_FILE"
    fi
    printf '%s\n' "$msg" >&2
}

next_stage_log() {
    local stage_name="$1"
    STAGE_COUNTER=$((STAGE_COUNTER + 1))
    printf "%02d-%s.log" "$STAGE_COUNTER" "$stage_name"
}

# =============================================================================
# STATUS FILE MANAGEMENT
# =============================================================================

init_status() {
    jq -n \
        --arg state "initializing" \
        --argjson issue "$ISSUE_NUMBER" \
        --arg base_branch "$BASE_BRANCH" \
        --arg branch "" \
        --arg worktree "" \
        --arg current_stage "setup" \
        --argjson current_task "null" \
        --arg log_dir "$LOG_BASE" \
        '{
            state: $state,
            issue: $issue,
            base_branch: $base_branch,
            branch: $branch,
            worktree: $worktree,
            current_stage: $current_stage,
            current_task: $current_task,
            stages: {
                setup: {status: "pending", started_at: null, completed_at: null},
                research: {status: "pending", started_at: null, completed_at: null},
                evaluate: {status: "pending", started_at: null, completed_at: null},
                plan: {status: "pending", started_at: null, completed_at: null},
                implement: {status: "pending", task_progress: "0/0"},
                quality_loop: {status: "pending", iteration: 0},
                test_loop: {status: "pending", iteration: 0},
                docs: {status: "pending"},
                pr: {status: "pending"},
                pr_review: {status: "pending", iteration: 0},
                complete: {status: "pending"}
            },
            tasks: [],
            quality_iterations: 0,
            test_iterations: 0,
            pr_review_iterations: 0,
            last_update: (now | todate),
            log_dir: $log_dir
        }' > "$STATUS_FILE"

    log "Initialized status file: $STATUS_FILE"
    sync_status_to_log
}

set_stage_started() {
    local stage="$1"
    jq --arg stage "$stage" \
       '.stages[$stage].started_at = (now | todate) |
        .stages[$stage].status = "in_progress" |
        .current_stage = $stage |
        .state = "running" |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

set_stage_completed() {
    local stage="$1"
    jq --arg stage "$stage" \
       '.stages[$stage].completed_at = (now | todate) |
        .stages[$stage].status = "completed" |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

update_task() {
    local task_id="$1"
    local status="$2"
    local review_attempts="${3:-0}"

    jq --argjson id "$task_id" \
       --arg status "$status" \
       --argjson attempts "$review_attempts" \
       '(.tasks[] | select(.id == $id)).status = $status |
        (.tasks[] | select(.id == $id)).review_attempts = $attempts |
        .current_task = $id |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

set_tasks() {
    local tasks_json="$1"
    jq --argjson tasks "$tasks_json" \
       '.tasks = $tasks |
        .stages.implement.task_progress = "0/\($tasks | length)" |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

set_worktree_info() {
    local worktree="$1"
    local branch="$2"
    jq --arg worktree "$worktree" \
       --arg branch "$branch" \
       '.worktree = $worktree | .branch = $branch | .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

set_final_state() {
    local state="$1"
    jq --arg state "$state" \
       '.state = $state | .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

increment_quality_iteration() {
    jq '.quality_iterations += 1 |
        .stages.quality_loop.iteration = .quality_iterations |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

increment_test_iteration() {
    jq '.test_iterations += 1 |
        .stages.test_loop.iteration = .test_iterations |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

increment_pr_review_iteration() {
    jq '.pr_review_iterations += 1 |
        .stages.pr_review.iteration = .pr_review_iterations |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

# =============================================================================
# RESUME FUNCTIONALITY
# =============================================================================

# Validate that a status file has required fields for resumption
# Returns 0 if valid, 1 if invalid
validate_resume_status() {
    local status_path="$1"

    if [[ ! -f "$status_path" ]]; then
        echo "ERROR: Status file not found: $status_path" >&2
        return 1
    fi

    # Check required fields exist
    local required_fields=("issue" "branch" "worktree" "current_stage" "log_dir")
    local field
    for field in "${required_fields[@]}"; do
        local value
        value=$(jq -r ".$field // empty" "$status_path" 2>/dev/null)
        if [[ -z "$value" || "$value" == "null" ]]; then
            echo "ERROR: Status file missing required field: $field" >&2
            return 1
        fi
    done

    # Check state is resumable (not already completed or in error)
    local state
    state=$(jq -r '.state' "$status_path" 2>/dev/null)
    if [[ "$state" == "completed" ]]; then
        echo "ERROR: Cannot resume - workflow already completed" >&2
        return 1
    fi

    return 0
}

# Load resume state from status file
# Sets global variables: ISSUE_NUMBER, BASE_BRANCH, LOG_BASE, WORKTREE, BRANCH
# Also sets: RESUME_STAGE, RESUME_TASK, RESUME_TASKS_JSON
load_resume_state() {
    local status_path="$1"

    ISSUE_NUMBER=$(jq -r '.issue' "$status_path")
    # Restore BASE_BRANCH from status file (fall back to command-line value if not stored)
    local stored_base_branch
    stored_base_branch=$(jq -r '.base_branch // empty' "$status_path")
    if [[ -n "$stored_base_branch" ]]; then
        BASE_BRANCH="$stored_base_branch"
    elif [[ -z "$BASE_BRANCH" ]]; then
        echo "WARNING: No base_branch in status file and none provided via --branch" >&2
    fi
    BRANCH=$(jq -r '.branch' "$status_path")
    WORKTREE=$(jq -r '.worktree' "$status_path")
    LOG_BASE=$(jq -r '.log_dir' "$status_path")

    RESUME_STAGE=$(jq -r '.current_stage' "$status_path")
    RESUME_TASK=$(jq -r '.current_task // 0' "$status_path")
    RESUME_TASKS_JSON=$(jq -c '.tasks // []' "$status_path")

    # Restore iteration counters (reserved for future resume functionality)
    # shellcheck disable=SC2034
    RESUME_QUALITY_ITERATIONS=$(jq -r '.quality_iterations // 0' "$status_path")
    # shellcheck disable=SC2034
    RESUME_TEST_ITERATIONS=$(jq -r '.test_iterations // 0' "$status_path")
    # shellcheck disable=SC2034
    RESUME_PR_ITERATIONS=$(jq -r '.pr_review_iterations // 0' "$status_path")

    # Get PR number if it exists
    # shellcheck disable=SC2034
    RESUME_PR_NUMBER=$(jq -r '.stages.pr.pr_number // empty' "$status_path")
}

# Check if a stage is completed in status file
# Returns 0 if completed, 1 if not
is_stage_completed() {
    local stage="$1"
    local status
    status=$(jq -r ".stages.$stage.status" "$STATUS_FILE" 2>/dev/null)
    [[ "$status" == "completed" ]]
}

# Get count of completed tasks
get_completed_task_count() {
    jq '[.tasks[] | select(.status == "completed")] | length' "$STATUS_FILE" 2>/dev/null || echo "0"
}

# Check if worktree exists and is valid
validate_worktree() {
    local worktree_path="$1"

    if [[ ! -d "$worktree_path" ]]; then
        echo "ERROR: Worktree not found: $worktree_path" >&2
        return 1
    fi

    if [[ ! -d "$worktree_path/.git" && ! -f "$worktree_path/.git" ]]; then
        echo "ERROR: Path is not a git worktree: $worktree_path" >&2
        return 1
    fi

    return 0
}

# =============================================================================
# RESUME MODE INITIALIZATION
# =============================================================================

# These will be populated in resume mode
WORKTREE=""
BRANCH=""
RESUME_STAGE=""
RESUME_TASK=""
RESUME_TASKS_JSON=""
# shellcheck disable=SC2034 # Reserved for future resume functionality
RESUME_QUALITY_ITERATIONS=0
# shellcheck disable=SC2034
RESUME_TEST_ITERATIONS=0
# shellcheck disable=SC2034
RESUME_PR_ITERATIONS=0
# shellcheck disable=SC2034
RESUME_PR_NUMBER=""

if [[ "$RESUME_MODE" == "logdir" ]]; then
    # Resume from specific log directory
    if [[ ! -d "$RESUME_LOG_DIR" ]]; then
        echo "ERROR: Log directory not found: $RESUME_LOG_DIR" >&2
        exit 1
    fi

    local_status_file="$RESUME_LOG_DIR/status.json"
    if [[ ! -f "$local_status_file" ]]; then
        # Try parent directory's status.json (log_dir may be relative)
        local_status_file="status.json"
    fi

    if ! validate_resume_status "$local_status_file"; then
        exit 1
    fi

    load_resume_state "$local_status_file"
    STATUS_FILE="$local_status_file"
    # LOG_BASE was set by load_resume_state

    if ! validate_worktree "$WORKTREE"; then
        exit 1
    fi

elif [[ "$RESUME_MODE" == "status" ]]; then
    # Resume from current status file
    if ! validate_resume_status "$STATUS_FILE"; then
        exit 1
    fi

    load_resume_state "$STATUS_FILE"

    if ! validate_worktree "$WORKTREE"; then
        exit 1
    fi

else
    # Normal mode - set LOG_BASE
    LOG_BASE="logs/implement-issue/issue-${ISSUE_NUMBER}-$(date +%Y%m%d-%H%M%S)"
fi

# Display mode info
if [[ -n "$RESUME_MODE" ]]; then
    echo "Implement Issue Orchestrator (RESUME MODE)"
    echo "Resuming from: $STATUS_FILE"
    echo "Issue: #$ISSUE_NUMBER"
    echo "Branch: $BRANCH"
    echo "Worktree: $WORKTREE"
    echo "Resume stage: $RESUME_STAGE"
    [[ -n "$RESUME_TASK" && "$RESUME_TASK" != "null" ]] && echo "Resume task: $RESUME_TASK"
    echo "Log dir: $LOG_BASE"
else
    echo "Implement Issue Orchestrator"
    echo "Issue: #$ISSUE_NUMBER"
    echo "Branch: $BASE_BRANCH"
    echo "Agent: ${AGENT:-default}"
    echo "Status file: $STATUS_FILE"
    echo "Log dir: $LOG_BASE"
fi

# Create log directories
mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"
LOG_FILE="$LOG_BASE/orchestrator.log"
STAGE_COUNTER=0

# =============================================================================
# STATUS SYNC TO LOG DIRECTORY
# =============================================================================

# Sync status.json to log directory after every update
# This ensures status.json exists in LOG_BASE for resume-from functionality
sync_status_to_log() {
	if [[ -n "$LOG_BASE" && -d "$LOG_BASE" && -f "$STATUS_FILE" ]]; then
		local target="$LOG_BASE/status.json"
		# Avoid copying file to itself (happens with --resume-from)
		if [[ "$(realpath "$STATUS_FILE")" != "$(realpath "$target")" ]]; then
			cp "$STATUS_FILE" "$target"
		fi
	fi
}

# =============================================================================
# GITHUB COMMENT HELPERS
# =============================================================================

REPO=$(git remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[:/]##; s/\.git$//')

# comment_issue <title> <body> [agent]
# If agent is provided, shows "Written by `agent`", otherwise "Posted by orchestrator"
comment_issue() {
	local title="$1"
	local body="$2"
	local agent="${3:-}"
	local attribution

	if [[ -n "$agent" ]]; then
		attribution="Written by \`$agent\`"
	else
		attribution="Posted by \`implement-issue-orchestrator\`"
	fi

	local comment
	comment=$(cat <<EOF
## $title
###### *$attribution*

$body
EOF
)

	log "Commenting on issue #$ISSUE_NUMBER: $title"
	if ! gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "$comment" 2>/dev/null; then
		log_error "Failed to comment on issue #$ISSUE_NUMBER"
	fi
}

# comment_pr <pr_num> <title> <body> [agent]
# If agent is provided, shows "Written by `agent`", otherwise "Posted by orchestrator"
comment_pr() {
	local pr_num="$1"
	local title="$2"
	local body="$3"
	local agent="${4:-}"
	local attribution

	if [[ -n "$agent" ]]; then
		attribution="Written by \`$agent\`"
	else
		attribution="Posted by \`implement-issue-orchestrator\`"
	fi

	local comment
	comment=$(cat <<EOF
## $title
###### *$attribution*

$body
EOF
)

	log "Commenting on PR #$pr_num: $title"
	if ! gh pr comment "$pr_num" --repo "$REPO" --body "$comment" 2>/dev/null; then
		log_error "Failed to comment on PR #$pr_num"
	fi
}

# =============================================================================
# RATE LIMIT DETECTION
# =============================================================================

detect_rate_limit() {
    local output="$1"

    # Check structured output first
    local status
    status=$(printf '%s' "$output" | jq -r '.structured_output.status // empty' 2>/dev/null)

    if [[ "$status" == "success" ]]; then
        return 1
    fi

    if [[ "$status" == "rate_limit" ]]; then
        return 0
    fi

    # Only check text patterns if there's an actual error
    # (prevents false positives when reviews mention "rate limiting" as a feature)
    local is_error
    is_error=$(printf '%s' "$output" | jq -r '.is_error // false' 2>/dev/null)

    if [[ "$is_error" != "true" ]]; then
        return 1
    fi

    # Fallback to text pattern matching (only for errors)
    local result
    result=$(printf '%s' "$output" | jq -r '.result // empty' 2>/dev/null)
    if printf '%s' "$result" | grep -qiE 'rate.limit|429|too many requests|quota.exceeded'; then
        return 0
    fi

    return 1
}

extract_wait_time() {
    local output="$1"
    local result
    result=$(printf '%s' "$output" | jq -r '.result // empty' 2>/dev/null)
    local search_text="$result $output"

    # Try retry-after
    local retry_after
    retry_after=$(printf '%s' "$search_text" | grep -oiE 'retry.after[^0-9]*([0-9]+)' | grep -oE '[0-9]+' | head -1)
    if [[ -n "$retry_after" ]] && (( retry_after > 0 )); then
        printf '%s\n' "$retry_after"
        return
    fi

    # Try wait X minutes
    local wait_mins
    wait_mins=$(printf '%s' "$search_text" | grep -oiE 'wait[^0-9]*([0-9]+)[^0-9]*min' | grep -oE '[0-9]+' | head -1)
    if [[ -n "$wait_mins" ]] && (( wait_mins > 0 )); then
        printf '%s\n' "$((wait_mins * 60))"
        return
    fi

    printf '%s\n' "$RATE_LIMIT_DEFAULT_WAIT"
}

handle_rate_limit() {
    local output="$1"
    local wait_time
    wait_time=$(extract_wait_time "$output")
    wait_time=$((wait_time + RATE_LIMIT_BUFFER))

    local resume_at
    resume_at=$(date -Iseconds -d "+${wait_time} seconds" 2>/dev/null || date -v+${wait_time}S -Iseconds 2>/dev/null)

    log "Rate limit hit. Waiting ${wait_time}s until $resume_at"
    sleep "$wait_time"
}

# =============================================================================
# STAGE RUNNERS
# =============================================================================

run_stage() {
    local stage_name="$1"
    local prompt="$2"
    local schema_file="$3"
    local agent="${4:-}"

    local stage_log
    stage_log="$LOG_BASE/stages/$(next_stage_log "$stage_name")"

    # Validate schema file exists
    if [[ ! -f "$SCHEMA_DIR/$schema_file" ]]; then
        log_error "Schema file not found: $SCHEMA_DIR/$schema_file"
        echo '{"status":"error","error":"schema not found"}'
        return 1
    fi

    local schema
    schema=$(jq -c . "$SCHEMA_DIR/$schema_file")

    log "Running stage: $stage_name"
    log "  Schema: $schema_file"
    log "  Agent: ${agent:-default}"
    log "  Log: $stage_log"

    local -a agent_args=()
    if [[ -n "$agent" ]]; then
        agent_args=(--agent "$agent")
    fi

    local output
    local exit_code=0

    output=$(timeout "$STAGE_TIMEOUT" claude -p "$prompt" \
        "${agent_args[@]}" \
        --dangerously-skip-permissions \
        --output-format json \
        --json-schema "$schema" \
        2>&1) || exit_code=$?

    {
        printf '%s\n' "=== $stage_name output ==="
        printf '%s\n' "$output"
        printf '%s\n' "=== exit code: $exit_code ==="
    } >> "$stage_log"

    # Check timeout
    if (( exit_code == 124 )); then
        log_error "Stage $stage_name timed out after ${STAGE_TIMEOUT}s"
        echo '{"status":"error","error":"timeout"}'
        return 1
    fi

    # Check rate limit
    if detect_rate_limit "$output"; then
        handle_rate_limit "$output"
        # Retry
        output=$(timeout "$STAGE_TIMEOUT" claude -p "$prompt" \
            "${agent_args[@]}" \
            --dangerously-skip-permissions \
            --output-format json \
            --json-schema "$schema" \
            2>&1) || exit_code=$?

        printf '%s\n' "=== $stage_name retry output ===" >> "$stage_log"
        printf '%s\n' "$output" >> "$stage_log"
    fi

    # Extract structured output
    local structured
    structured=$(printf '%s' "$output" | jq -c '.structured_output // empty' 2>/dev/null)

    if [[ -z "$structured" ]]; then
        log_error "No structured output from $stage_name"
        echo '{"status":"error","error":"no structured output"}'
        return 1
    fi

    printf '%s\n' "$structured"
}

# =============================================================================
# QUALITY LOOP HELPER
# =============================================================================

# Run the quality loop (simplify -> review -> fix, repeat)
# Note: Testing is handled separately by run_test_loop after all tasks complete
# Arguments:
#   $1 - worktree path
#   $2 - branch name
#   $3 - stage prefix for logging (e.g., "task-1" or "pr-fix")
# Returns:
#   0 on success (approved)
#   2 on max iterations exceeded (calls exit 2)
run_quality_loop() {
    local loop_worktree="$1"
    local loop_branch="$2"
    local stage_prefix="${3:-main}"

    local loop_approved=false
    local loop_iteration=0  # Per-loop counter (resets each call)

    while [[ "$loop_approved" != "true" ]]; do
        loop_iteration=$((loop_iteration + 1))
        increment_quality_iteration  # Global counter for status tracking

        if (( loop_iteration > MAX_QUALITY_ITERATIONS )); then
            log_error "Quality loop for $stage_prefix exceeded max iterations ($MAX_QUALITY_ITERATIONS)"
            set_final_state "max_iterations_quality"
            exit 2
        fi

        log "Quality loop iteration $loop_iteration/$MAX_QUALITY_ITERATIONS (prefix: $stage_prefix)"

        # -------------------------------------------------------------------------
        # SIMPLIFY → Issue comment #7
        # -------------------------------------------------------------------------
        local simplify_prompt="Run cdd-code-simplifier on modified files in worktree $loop_worktree on branch $loop_branch.

IMPORTANT SCOPE CONSTRAINT: This is for issue #$ISSUE_NUMBER. Only simplify code that is directly related to the issue's goals. Do NOT apply general refactoring to files that were only incidentally touched or are outside the issue's focus area.

If no relevant files were modified as part of this issue's implementation, make no changes and report 'No changes to simplify'.

Simplify code for clarity and consistency without changing functionality. Follow STYLEGUIDE.md conventions for shell scripts.
Output a summary of changes made."

        local simplify_result
        simplify_result=$(run_stage "simplify-${stage_prefix}-iter-$loop_iteration" "$simplify_prompt" "implement-issue-simplify.json" "cdd-code-simplifier")

        local simplify_summary
        simplify_summary=$(printf '%s' "$simplify_result" | jq -r '.summary // "No changes"')

        # Comment #7: Simplify summary
        comment_issue "Quality Loop [$stage_prefix]: Simplify ($loop_iteration/$MAX_QUALITY_ITERATIONS)" "$simplify_summary" "cdd-code-simplifier"

        # -------------------------------------------------------------------------
        # REVIEW → Issue comment #9
        # -------------------------------------------------------------------------
        local review_prompt="Review the code changes for task scope '$stage_prefix' in worktree $loop_worktree on branch $loop_branch.

IMPORTANT: This is a task-level quality check within the implementation workflow, NOT a full PR review.
Your job is to verify code quality for the changes made in this task only.

Check:
- Code patterns and standards
- Consistency with codebase conventions
- Potential bugs or issues
- Security concerns

DO NOT recommend 'approve and merge' - this is not a PR review.
Simply output 'approved' if code quality is acceptable, or 'changes_requested' with specific issues to fix."

        local review_result
        review_result=$(run_stage "review-${stage_prefix}-iter-$loop_iteration" "$review_prompt" "implement-issue-review.json" "code-reviewer")

        local review_verdict review_summary
        review_verdict=$(printf '%s' "$review_result" | jq -r '.result')
        review_summary=$(printf '%s' "$review_result" | jq -r '.summary // "Review completed"')

        # Comment #9: Code review results
        local review_icon="✅"
        [[ "$review_verdict" == "changes_requested" ]] && review_icon="🔄"
        comment_issue "Quality Loop [$stage_prefix]: Code Review ($loop_iteration/$MAX_QUALITY_ITERATIONS)" "$review_icon **Result:** $review_verdict

$review_summary" "code-reviewer"

        if [[ "$review_verdict" == "approved" ]]; then
            loop_approved=true
            log "Quality loop for $stage_prefix approved on iteration $loop_iteration"
        else
            local review_comments
            review_comments=$(printf '%s' "$review_result" | jq -r '.comments // "No comments"')
            printf '%s\n' "$review_comments" >> "$LOG_BASE/context/review-comments.json"

            local fix_prompt="Address code review feedback in worktree $loop_worktree on branch $loop_branch:

$review_comments

Fix the issues and commit. Output a summary of fixes applied."

            local fix_result
            fix_result=$(run_stage "fix-review-${stage_prefix}-iter-$loop_iteration" "$fix_prompt" "implement-issue-fix.json")

            local fix_summary
            fix_summary=$(printf '%s' "$fix_result" | jq -r '.summary // "Fixes applied"')

            # Comment #10: Fix results (review fix)
            comment_issue "Quality Loop [$stage_prefix]: Review Fix ($loop_iteration/$MAX_QUALITY_ITERATIONS)" "$fix_summary"
        fi
    done

    return 0
}

# =============================================================================
# TEST LOOP HELPER
# =============================================================================

# Run the test loop (test -> validate -> fix, repeat until pass)
# Called once after all tasks complete
# Flow:
#   1. Run lint + tests (shellcheck, BATS)
#   2. If tests fail: fix issues, loop
#   3. If tests pass: validate test quality (bats-test-validator, scoped to issue)
#   4. If validation fails: fix issues, loop
#   5. If validation passes: done
# Arguments:
#   $1 - worktree path
#   $2 - branch name
# Returns:
#   0 on success (tests pass and validated)
#   2 on max iterations exceeded (calls exit 2)
run_test_loop() {
    local loop_worktree="$1"
    local loop_branch="$2"

    local loop_complete=false
    local test_iteration=0

    log "Starting test loop after all tasks complete"

    while [[ "$loop_complete" != "true" ]]; do
        test_iteration=$((test_iteration + 1))
        increment_test_iteration  # Track iteration in status file

        if (( test_iteration > MAX_TEST_ITERATIONS )); then
            log_error "Test loop exceeded max iterations ($MAX_TEST_ITERATIONS)"
            set_final_state "max_iterations_test"
            exit 2
        fi

        log "Test loop iteration $test_iteration/$MAX_TEST_ITERATIONS"

        # -------------------------------------------------------------------------
        # TEST EXECUTION → Issue comment
        # -------------------------------------------------------------------------
        local test_prompt="Run the test and lint suite in worktree $loop_worktree:

1. Run shellcheck on all modified .sh files: git -C $loop_worktree diff $BASE_BRANCH...HEAD --name-only -- '*.sh' | xargs shellcheck
2. Run actionlint on any modified workflow files: git -C $loop_worktree diff $BASE_BRANCH...HEAD --name-only -- '.github/workflows/*.yml' | xargs actionlint
3. If BATS tests exist, run them: cd $loop_worktree && bats .claude/scripts/implement-issue-test/

Report pass/fail, test counts, and any failures. Output a summary suitable for a GitHub comment."

        local test_result
        test_result=$(run_stage "test-loop-iter-$test_iteration" "$test_prompt" "implement-issue-test.json" "bats-test-validator")

        local test_status test_summary
        test_status=$(printf '%s' "$test_result" | jq -r '.result')
        test_summary=$(printf '%s' "$test_result" | jq -r '.summary // "Tests completed"')

        # Comment: Test results
        local test_icon="✅"
        [[ "$test_status" == "failed" ]] && test_icon="❌"
        comment_issue "Test Loop: Tests ($test_iteration/$MAX_TEST_ITERATIONS)" "$test_icon **Result:** $test_status

$test_summary" "bats-test-validator"

        if [[ "$test_status" == "failed" ]]; then
            log "Tests failed. Getting failures and fixing..."
            local failures
            failures=$(printf '%s' "$test_result" | jq -c '.failures')

            local fix_prompt="Fix test failures in worktree $loop_worktree on branch $loop_branch:

Failures:
$failures

Fix the issues and commit. Output a summary of fixes applied."

            local fix_result
            fix_result=$(run_stage "fix-tests-iter-$test_iteration" "$fix_prompt" "implement-issue-fix.json" "bash-script-craftsman")

            local fix_summary
            fix_summary=$(printf '%s' "$fix_result" | jq -r '.summary // "Fixes applied"')

            # Comment: Fix results
            comment_issue "Test Loop: Test Fix ($test_iteration/$MAX_TEST_ITERATIONS)" "$fix_summary" "bash-script-craftsman"
            continue
        fi

        # -------------------------------------------------------------------------
        # TEST VALIDATION → Issue comment (only if tests passed)
        # -------------------------------------------------------------------------
        log "Tests passed. Running test validation for issue #$ISSUE_NUMBER..."

        local validate_prompt="Validate test comprehensiveness and integrity for issue #$ISSUE_NUMBER in worktree $loop_worktree.

SCOPE: Only validate tests related to this issue's implementation. Get modified shell scripts with:
git -C $loop_worktree diff $BASE_BRANCH...HEAD --name-only -- '*.sh' '*.bats'

IMPORTANT SCOPE CONSTRAINTS:
- If NO testable shell scripts were modified (e.g., docs-only, CI config, metadata changes), output 'passed' immediately. Do NOT request new tests for non-script changes.
- Only validate tests for modified .sh files
- Do NOT request tests for README, CLAUDE.md, package metadata, or workflow YAML

For each modified script that warrants testing, identify the corresponding BATS test file and audit:
1. Run BATS tests if they exist: cd $loop_worktree && bats .claude/scripts/implement-issue-test/
2. Check for TODO/FIXME/incomplete tests
3. Check for hollow assertions (no assertions after run)
4. Verify edge cases and error conditions are tested
5. Check for common BATS gotchas (pipes with run, echo mangling, tee pollution)

Output:
- result: 'passed' if tests are comprehensive OR if no testable scripts were modified, 'failed' if issues found
- issues: array of issues found (if any)
- summary: suitable for a GitHub comment (note if validation was skipped due to no testable script changes)"

        local validate_result
        validate_result=$(run_stage "test-validate-iter-$test_iteration" "$validate_prompt" "implement-issue-review.json" "bats-test-validator")

        local validate_status validate_summary
        validate_status=$(printf '%s' "$validate_result" | jq -r '.result')
        validate_summary=$(printf '%s' "$validate_result" | jq -r '.summary // "Validation completed"')

        # Comment: Validation results
        local validate_icon="✅"
        [[ "$validate_status" == "changes_requested" || "$validate_status" == "failed" ]] && validate_icon="🔄"
        comment_issue "Test Loop: Validation ($test_iteration/$MAX_TEST_ITERATIONS)" "$validate_icon **Result:** $validate_status

$validate_summary" "bats-test-validator"

        if [[ "$validate_status" == "approved" || "$validate_status" == "passed" ]]; then
            loop_complete=true
            log "Test loop complete on iteration $test_iteration (tests passed and validated)"
        else
            log "Test validation found issues. Fixing..."
            local validate_comments
            validate_comments=$(printf '%s' "$validate_result" | jq -r '.comments // .summary // "Fix test quality issues"')

            local fix_prompt="Address test quality issues in worktree $loop_worktree on branch $loop_branch:

$validate_comments

Fix the test quality issues (add missing assertions, remove TODOs, add edge case tests, etc.) and commit.
Output a summary of fixes applied."

            local fix_result
            fix_result=$(run_stage "fix-test-quality-iter-$test_iteration" "$fix_prompt" "implement-issue-fix.json" "bash-script-craftsman")

            local fix_summary
            fix_summary=$(printf '%s' "$fix_result" | jq -r '.summary // "Fixes applied"')

            # Comment: Fix results
            comment_issue "Test Loop: Validation Fix ($test_iteration/$MAX_TEST_ITERATIONS)" "$fix_summary" "bash-script-craftsman"
        fi
    done

    return 0
}

# =============================================================================
# MAIN FLOW
# =============================================================================

main() {
    # Declare local variables used throughout main
    local worktree branch tasks_json task_count completed_tasks

    # -------------------------------------------------------------------------
    # RESUME VS FRESH START INITIALIZATION
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]]; then
        log "=========================================="
        log "Implement Issue Orchestrator RESUMING"
        log "=========================================="
        log "Issue: #$ISSUE_NUMBER"
        log "Branch: $BRANCH"
        log "Worktree: $WORKTREE"
        log "Resume stage: $RESUME_STAGE"
        log "Resume task: ${RESUME_TASK:-none}"
        log "Log dir: $LOG_BASE"

        # Use values from resume state
        worktree="$WORKTREE"
        branch="$BRANCH"
        tasks_json="$RESUME_TASKS_JSON"

        # Update status to indicate resumption
        jq --arg state "running" \
           '.state = $state | .last_update = (now | todate)' \
           "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
        sync_status_to_log

        # Comment on issue about resumption
        comment_issue "Resuming Automated Processing" "Resuming processing of issue #$ISSUE_NUMBER.

**Resuming from stage:** \`$RESUME_STAGE\`
**Worktree:** \`$worktree\`
**Branch:** \`$branch\`

Log directory: \`$LOG_BASE\`"

    else
        log "=========================================="
        log "Implement Issue Orchestrator Starting"
        log "=========================================="
        log "Issue: #$ISSUE_NUMBER"
        log "Branch: $BASE_BRANCH"
        log "Agent: ${AGENT:-default}"
        log "Log dir: $LOG_BASE"

        init_status

        # -------------------------------------------------------------------------
        # COMMENT #1: Starting automated processing
        # -------------------------------------------------------------------------
        comment_issue "Starting Automated Processing" "Processing issue #$ISSUE_NUMBER against branch \`$BASE_BRANCH\`.

**Stages:**
1. Setup worktree
2. Research context
3. Evaluate approach
4. Create implementation plan
5. Implement tasks (with per-task quality loop: simplify, review)
6. Test loop (run tests, fix failures)
7. Documentation
8. Create/update PR
9. PR review loop

Log directory: \`$LOG_BASE\`"
    fi

    # -------------------------------------------------------------------------
    # STAGE: SETUP (worktree creation)
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "setup"; then
        log "Skipping setup stage (already completed)"
    else
        set_stage_started "setup"

        local setup_prompt="Set up worktree for issue #$ISSUE_NUMBER against branch $BASE_BRANCH.

You must:
1. Fetch the issue title and body from GitHub using: gh issue view $ISSUE_NUMBER --repo $REPO --json title,body
2. Check for existing PR (if re-implementation)
3. Create or checkout worktree using using-git-worktrees skill

Output the worktree path and branch name."

        local setup_result
        setup_result=$(run_stage "setup" "$setup_prompt" "implement-issue-setup.json" "$AGENT")

        local setup_status
        setup_status=$(printf '%s' "$setup_result" | jq -r '.status')

        if [[ "$setup_status" != "success" ]]; then
            local error
            error=$(printf '%s' "$setup_result" | jq -r '.error // "unknown error"')
            log_error "Setup failed: $error"
            set_final_state "error"
            exit 1
        fi

        worktree=$(printf '%s' "$setup_result" | jq -r '.worktree')
        branch=$(printf '%s' "$setup_result" | jq -r '.branch')

        set_worktree_info "$worktree" "$branch"
        printf '%s\n' "$setup_result" > "$LOG_BASE/context/setup-output.json"

        set_stage_completed "setup"
        log "Setup complete. Worktree: $worktree, Branch: $branch"

        # -------------------------------------------------------------------------
        # VERIFY BUILD TOOLS (needed for build.sh)
        # -------------------------------------------------------------------------
        log "Verifying build tools are available..."
        local missing_tools=()
        for tool in 7z wget wrestool convert dpkg-deb node; do
            if ! command -v "$tool" &>/dev/null; then
                missing_tools+=("$tool")
            fi
        done
        if [[ ${#missing_tools[@]} -gt 0 ]]; then
            log "Warning: Missing build tools: ${missing_tools[*]} (run setup-build-tools skill if needed)"
        else
            log "Build tools verified"
        fi
    fi

    # -------------------------------------------------------------------------
    # STAGE: RESEARCH (no comment per user request)
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "research"; then
        log "Skipping research stage (already completed)"
    else
        set_stage_started "research"

        local research_prompt="Research context for issue #$ISSUE_NUMBER in worktree $worktree.

You must:
1. Read the issue details from GitHub
2. Explore related files and code structure
3. Identify dependencies and related components
4. Document relevant context for implementation

Output the research findings."

        local research_result
        research_result=$(run_stage "research" "$research_prompt" "implement-issue-research.json" "$AGENT")

        printf '%s\n' "$research_result" > "$LOG_BASE/context/research-output.json"

        set_stage_completed "research"
        log "Research complete."
    fi

    # -------------------------------------------------------------------------
    # STAGE: EVALUATE → Issue comment #3
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "evaluate"; then
        log "Skipping evaluate stage (already completed)"
    else
        set_stage_started "evaluate"

        local evaluate_prompt="Evaluate the best implementation approach for issue #$ISSUE_NUMBER.

Based on the research, determine:
1. The recommended approach
2. Rationale for this approach
3. Potential risks or concerns
4. Alternative approaches considered

Output your evaluation with a summary suitable for a GitHub comment."

        local evaluate_result
        evaluate_result=$(run_stage "evaluate" "$evaluate_prompt" "implement-issue-evaluate.json" "$AGENT")

        local evaluate_status
        evaluate_status=$(printf '%s' "$evaluate_result" | jq -r '.status')

        # Comment #3: Evaluate findings (always post, format based on status)
        local eval_summary approach rationale
        eval_summary=$(printf '%s' "$evaluate_result" | jq -r '.summary')
        approach=$(printf '%s' "$evaluate_result" | jq -r '.approach // ""')
        rationale=$(printf '%s' "$evaluate_result" | jq -r '.rationale // ""')

        if [[ "$evaluate_status" == "success" ]]; then
            local eval_body="**Approach:** $approach

**Rationale:** $rationale

$eval_summary"
            comment_issue "Evaluation: Best Path" "$eval_body" "${AGENT:-}"
        else
            local eval_error risks_text
            eval_error=$(printf '%s' "$evaluate_result" | jq -r '.error // "Unknown error"')
            risks_text=$(printf '%s' "$evaluate_result" | jq -r '.risks // [] | map("- " + .) | join("\n")')

            local eval_body="⚠️ **Status:** Error - requires attention

**Approach:** $approach

**Rationale:** $rationale

**Error:** $eval_error"

            if [[ -n "$risks_text" ]]; then
                eval_body="$eval_body

**Risks:**
$risks_text"
            fi

            comment_issue "Evaluation: Issue Concerns" "$eval_body" "${AGENT:-}"

            # Exit early - evaluation found blocking issues
            printf '%s\n' "$evaluate_result" > "$LOG_BASE/context/evaluate-output.json"
            set_stage_completed "evaluate"
            log_error "Evaluation found blocking issues. Exiting."
            set_final_state "blocked"
            exit 1
        fi

        printf '%s\n' "$evaluate_result" > "$LOG_BASE/context/evaluate-output.json"

        set_stage_completed "evaluate"
        log "Evaluation complete."
    fi

    # -------------------------------------------------------------------------
    # STAGE: PLAN → Issue comments #4 (plan) and #5 (task list)
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "plan"; then
        log "Skipping plan stage (already completed)"
        # Load tasks from status file for implement stage
        tasks_json=$(jq -c '.tasks' "$STATUS_FILE")
    else
        set_stage_started "plan"

        local plan_prompt="Create an implementation plan for issue #$ISSUE_NUMBER in worktree $worktree on branch $branch.

Based on the evaluation, you must:
1. Write a detailed implementation plan
2. Break down into tasks with agent assignments
3. Each task should specify: id, description, and agent. Available agents:
   - patch-engineer: minified JS patches in build.sh, sed/regex patterns
   - packaging-specialist: .deb, .rpm, AppImage packaging, control files
   - electron-linux-specialist: BrowserWindow, Wayland/X11, DBus tray, native theme
   - ci-workflow-architect: GitHub Actions workflows, release automation
   - bash-script-craftsman: shell scripts, launcher, build system

Output the plan path, task list, a summary of the plan, and a markdown-formatted task list for GitHub."

        local plan_result
        plan_result=$(run_stage "plan" "$plan_prompt" "implement-issue-plan.json" "$AGENT")

        local plan_status
        plan_status=$(printf '%s' "$plan_result" | jq -r '.status')

        if [[ "$plan_status" != "success" ]]; then
            local error
            error=$(printf '%s' "$plan_result" | jq -r '.error // "unknown error"')
            log_error "Plan failed: $error"
            set_final_state "error"
            exit 1
        fi

        local plan_summary task_list_md plan_path
        tasks_json=$(printf '%s' "$plan_result" | jq -c '.tasks')
        plan_summary=$(printf '%s' "$plan_result" | jq -r '.summary')
        task_list_md=$(printf '%s' "$plan_result" | jq -r '.task_list_markdown')
        plan_path=$(printf '%s' "$plan_result" | jq -r '.plan_path // empty')

        set_tasks "$tasks_json"
        printf '%s\n' "$plan_result" > "$LOG_BASE/context/plan-output.json"
        printf '%s\n' "$tasks_json" > "$LOG_BASE/context/tasks.json"

        # Comment #4: Implementation Plan (with full plan in collapsible)
        local plan_body="$plan_summary"
        if [[ -n "$plan_path" && -f "$worktree/$plan_path" ]]; then
            local plan_content
            plan_content=$(cat "$worktree/$plan_path")
            plan_body="$plan_summary

<details>
<summary>Full Implementation Plan</summary>

\`\`\`markdown
$plan_content
\`\`\`

</details>"
        fi
        comment_issue "Implementation Plan" "$plan_body"

        # Comment #5: Task List
        comment_issue "Task List" "$task_list_md"

        set_stage_completed "plan"
        log "Plan complete. Tasks: $(printf '%s' "$tasks_json" | jq length)"
    fi

    # -------------------------------------------------------------------------
    # STAGE: IMPLEMENT (per-task loop)
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "implement"; then
        log "Skipping implement stage (already completed)"
    else
        set_stage_started "implement"

        task_count=$(printf '%s' "$tasks_json" | jq length)

        # In resume mode, count already completed tasks
        if [[ -n "$RESUME_MODE" ]]; then
            completed_tasks=$(get_completed_task_count)
            log "Resuming implementation: $completed_tasks/$task_count tasks already completed"
        else
            completed_tasks=0
        fi

        for ((i=0; i<task_count; i++)); do
            local task
            task=$(printf '%s' "$tasks_json" | jq ".[$i]")
            local task_id task_desc task_agent task_status
            task_id=$(printf '%s' "$task" | jq -r '.id')
            task_desc=$(printf '%s' "$task" | jq -r '.description')
            task_agent=$(printf '%s' "$task" | jq -r '.agent')

            # In resume mode, check if this task is already completed
            if [[ -n "$RESUME_MODE" ]]; then
                task_status=$(jq -r ".tasks[] | select(.id == $task_id) | .status" "$STATUS_FILE" 2>/dev/null)
                if [[ "$task_status" == "completed" ]]; then
                    log "Skipping task $task_id (already completed)"
                    continue
                fi
            fi

            log "Implementing task $task_id: $task_desc (agent: $task_agent)"
            update_task "$task_id" "in_progress"

            local review_attempts=0
            local task_approved=false

            while [[ "$task_approved" != "true" ]] && (( review_attempts < MAX_TASK_REVIEW_ATTEMPTS )); do
                # Implement
                local impl_prompt="Implement task $task_id in worktree $worktree on branch $branch:

$task_desc

Commit your changes with a descriptive message."

                local impl_result
                impl_result=$(run_stage "implement-task-$task_id" "$impl_prompt" "implement-issue-implement.json" "$task_agent")

                local impl_status
                impl_status=$(printf '%s' "$impl_result" | jq -r '.status')

                if [[ "$impl_status" != "success" ]]; then
                    log_error "Task $task_id implementation failed"
                    update_task "$task_id" "failed" "$review_attempts"
                    break
                fi

                local commit_sha
                commit_sha=$(printf '%s' "$impl_result" | jq -r '.commit')

                # Review task
                local review_prompt="Review task $task_id implementation (commit $commit_sha):

Task description: $task_desc

Did the implementation achieve the task's goal? Are there suggested improvements?"

                local review_result
                review_result=$(run_stage "task-review-$task_id-attempt-$((review_attempts+1))" "$review_prompt" "implement-issue-task-review.json" "spec-reviewer")

                local review_verdict suggested_improvements
                review_verdict=$(printf '%s' "$review_result" | jq -r '.result')
                suggested_improvements=$(printf '%s' "$review_result" | jq -r '.suggested_improvements')

                if [[ "$review_verdict" == "passed" && "$suggested_improvements" != "yes" ]]; then
                    task_approved=true
                    update_task "$task_id" "completed" "$((review_attempts+1))"
                    completed_tasks=$((completed_tasks+1))

                    # Comment #6: Task complete (with summary from implementing agent)
                    local impl_summary
                    impl_summary=$(printf '%s' "$impl_result" | jq -r '.summary // "Implementation completed"')
                    comment_issue "Task $task_id Complete" "**$task_desc**

**Commit:** \`$commit_sha\`

$impl_summary" "$task_agent"

                    # Run quality loop for this task
                    log "Running quality loop for task $task_id"
                    run_quality_loop "$worktree" "$branch" "task-$task_id"

                else
                    review_attempts=$((review_attempts+1))
                    local review_comments
                    review_comments=$(printf '%s' "$review_result" | jq -r '.comments // "No comments"')

                    log "Task $task_id needs fixes (attempt $review_attempts/$MAX_TASK_REVIEW_ATTEMPTS)"

                    # Fix
                    local fix_prompt="Fix issues in task $task_id (commit $commit_sha) in worktree $worktree on branch $branch:

Review feedback:
$review_comments

Address the issues and commit."

                    run_stage "fix-task-$task_id-attempt-$review_attempts" "$fix_prompt" "implement-issue-fix.json" "$task_agent"
                fi
            done

            # Update progress
            jq --arg progress "$completed_tasks/$task_count" \
               '.stages.implement.task_progress = $progress | .last_update = (now | todate)' \
               "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
            sync_status_to_log
        done

        set_stage_completed "implement"
        set_stage_completed "quality_loop"  # Quality loop ran per-task
        log "Implementation complete. $completed_tasks/$task_count tasks completed (with per-task quality loops)."
    fi

    # -------------------------------------------------------------------------
    # STAGE: TEST LOOP (after all tasks complete)
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "test_loop"; then
        log "Skipping test_loop stage (already completed)"
    else
        set_stage_started "test_loop"
        log "Running test loop after all tasks complete..."

        run_test_loop "$worktree" "$branch"

        set_stage_completed "test_loop"
        log "Test loop complete."
    fi

    # -------------------------------------------------------------------------
    # STAGE: LINT (final lint check before PR)
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "docs"; then
        log "Skipping lint stage (already completed)"
    else
        set_stage_started "docs"

        local lint_prompt="Run final lint checks on all modified files in worktree $worktree on branch $branch.

Get modified files with: git -C $worktree diff $BASE_BRANCH...HEAD --name-only

For .sh files: run shellcheck
For .github/workflows/*.yml files: run actionlint

If any issues are found, fix them and commit with message: style(issue-$ISSUE_NUMBER): fix lint issues

Output a summary of any lint fixes applied."

        run_stage "lint" "$lint_prompt" "implement-issue-implement.json" "bash-script-craftsman"

        set_stage_completed "docs"
    fi

    # -------------------------------------------------------------------------
    # STAGE: PR
    # -------------------------------------------------------------------------
    local pr_number

    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "pr"; then
        log "Skipping PR creation stage (already completed)"
        # Load PR number from status
        pr_number=$(jq -r '.stages.pr.pr_number // empty' "$STATUS_FILE")
        if [[ -z "$pr_number" || "$pr_number" == "null" ]]; then
            log_error "PR stage marked complete but no PR number found in status"
            set_final_state "error"
            exit 1
        fi
        log "Using existing PR #$pr_number"
    else
        set_stage_started "pr"

        local pr_prompt="Create or update PR for issue #$ISSUE_NUMBER in worktree $worktree.

If no PR exists, create one:
gh pr create --base $BASE_BRANCH --title 'feat(issue-$ISSUE_NUMBER): <description>'

If PR exists, push and comment.

Include 'Closes #$ISSUE_NUMBER' in the body."

        local pr_result
        pr_result=$(run_stage "pr" "$pr_prompt" "implement-issue-pr.json")

        local pr_status
        pr_status=$(printf '%s' "$pr_result" | jq -r '.status')
        pr_number=$(printf '%s' "$pr_result" | jq -r '.pr_number')

        if [[ "$pr_status" != "success" ]]; then
            log_error "PR creation failed"
            set_final_state "error"
            exit 1
        fi

        log "PR #$pr_number created/updated"

        # Store PR info in status
        jq --argjson pr "$pr_number" \
           '.stages.pr.pr_number = $pr | .last_update = (now | todate)' \
           "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
        sync_status_to_log
        set_stage_completed "pr"
    fi

    # -------------------------------------------------------------------------
    # STAGE: PR REVIEW LOOP
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "pr_review"; then
        log "Skipping pr_review stage (already completed)"
    else
        set_stage_started "pr_review"

        local pr_approved=false

    while [[ "$pr_approved" != "true" ]]; do
        increment_pr_review_iteration
        local pr_iteration
        pr_iteration=$(jq -r '.pr_review_iterations' "$STATUS_FILE")

        if (( pr_iteration > MAX_PR_REVIEW_ITERATIONS )); then
            log_error "PR review loop exceeded max iterations ($MAX_PR_REVIEW_ITERATIONS)"
            set_final_state "max_iterations_pr_review"
            exit 2
        fi

        log "PR review iteration $pr_iteration"

        # -------------------------------------------------------------------------
        # SPEC REVIEW → PR comment #11
        # -------------------------------------------------------------------------
        local spec_prompt="Verify PR #$pr_number achieves the goals of issue #$ISSUE_NUMBER.

Check goal achievement, not code quality. Flag scope creep.
Output a summary suitable for a GitHub comment."

        local spec_result
        spec_result=$(run_stage "spec-review-iter-$pr_iteration" "$spec_prompt" "implement-issue-review.json" "spec-reviewer")

        local spec_verdict spec_summary
        spec_verdict=$(printf '%s' "$spec_result" | jq -r '.result')
        spec_summary=$(printf '%s' "$spec_result" | jq -r '.summary // "Review completed"')

        # Comment #11: PR Spec Review Result
        local spec_icon="✅"
        [[ "$spec_verdict" == "changes_requested" ]] && spec_icon="🔄"
        comment_pr "$pr_number" "Spec Review (Iteration $pr_iteration)" "$spec_icon **Result:** $spec_verdict

$spec_summary" "spec-reviewer"

        # -------------------------------------------------------------------------
        # CODE REVIEW → PR comment #12
        # -------------------------------------------------------------------------
        local code_prompt="Review code quality of PR #$pr_number against base $BASE_BRANCH.

Check patterns, standards, security. Approve or request changes.
Output a summary suitable for a GitHub comment."

        local code_result
        code_result=$(run_stage "code-review-iter-$pr_iteration" "$code_prompt" "implement-issue-review.json" "code-reviewer")

        local code_verdict code_summary
        code_verdict=$(printf '%s' "$code_result" | jq -r '.result')
        code_summary=$(printf '%s' "$code_result" | jq -r '.summary // "Review completed"')

        # Comment #12: PR Code Review Result
        local code_icon="✅"
        [[ "$code_verdict" == "changes_requested" ]] && code_icon="🔄"
        comment_pr "$pr_number" "Code Review (Iteration $pr_iteration)" "$code_icon **Result:** $code_verdict

$code_summary" "code-reviewer"

        if [[ "$spec_verdict" == "approved" && "$code_verdict" == "approved" ]]; then
            pr_approved=true
            log "PR approved on iteration $pr_iteration"
        else
            log "PR review requested changes. Fixing and re-running quality loop."

            # Collect feedback
            local spec_comments code_comments
            spec_comments=$(printf '%s' "$spec_result" | jq -r '.comments // ""')
            code_comments=$(printf '%s' "$code_result" | jq -r '.comments // ""')

            local fix_prompt="Address PR review feedback in worktree $worktree on branch $branch:

Spec review:
$spec_comments

Code review:
$code_comments

Fix the issues and commit. Output a summary of fixes applied."

            local fix_result
            fix_result=$(run_stage "fix-pr-review-iter-$pr_iteration" "$fix_prompt" "implement-issue-fix.json")

            local fix_summary
            fix_summary=$(printf '%s' "$fix_result" | jq -r '.summary // "Fixes applied"')

            # Comment #13: PR Fix Result
            comment_pr "$pr_number" "PR Review Fix (Iteration $pr_iteration)" "$fix_summary"

            # Re-run quality loop after PR review fixes
            log "Re-running quality loop after PR review fixes..."
            run_quality_loop "$worktree" "$branch" "pr-fix"

            # Push updates
            log "Pushing updates to PR..."
            git -C "$worktree" push origin "$branch" 2>/dev/null || log "Warning: Could not push to origin"
        fi
        done

        set_stage_completed "pr_review"
    fi

    # -------------------------------------------------------------------------
    # STAGE: COMPLETE → PR comment #14
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "complete"; then
        log "Workflow already completed"
    else
        set_stage_started "complete"

        local complete_prompt="Generate a completion summary for PR #$pr_number implementing issue #$ISSUE_NUMBER.

Include:
- Issue and branch info
- Decisions made during implementation
- Reviews passed
- Final status

Output a summary suitable for a GitHub PR comment."

        local complete_result
        complete_result=$(run_stage "complete" "$complete_prompt" "implement-issue-complete.json")

        local complete_summary
        complete_summary=$(printf '%s' "$complete_result" | jq -r '.summary // "Implementation completed successfully"')

        # Comment #14: Implementation complete
        comment_pr "$pr_number" "Implementation Complete" "Issue #$ISSUE_NUMBER has been implemented!

**Branch:** \`$branch\`
**PR:** #$pr_number

$complete_summary

---
*This PR is ready for human review and merge.*"

        set_stage_completed "complete"
        set_final_state "completed"
    fi

    # Copy final status to log dir
    cp "$STATUS_FILE" "$LOG_BASE/status.json"

    log "=========================================="
    log "Implement Issue Complete"
    log "=========================================="
    log "Issue: #$ISSUE_NUMBER"
    log "PR: #$pr_number"
    log "Branch: $branch"
    log "Status: completed"

    exit 0
}

# Run main
main "$@"
