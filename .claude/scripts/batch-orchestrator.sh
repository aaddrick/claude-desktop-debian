#!/usr/bin/env bash
#
# batch-orchestrator.sh
# Orchestrates batch processing of GitHub issues using Claude Agent SDK
#
# Usage:
#   ./batch-orchestrator.sh --manifest <path>
#   ./batch-orchestrator.sh --issues "123,124,125" --branch "test"
#   ./batch-orchestrator.sh --manifest <path> --agent patch-engineer
#
# Agent Selection:
#   --agent <name>  Specify agent for implement-issue (e.g., patch-engineer,
#                   packaging-specialist). Process-pr always uses code-reviewer.
#
# Outputs:
#   - status.json: Real-time progress (read by handle-issues skill)
#   - logs/batch-<timestamp>/: Per-issue logs and final summary
#
# Exit codes:
#   0  - All issues processed successfully
#   1  - Some issues failed (check status.json)
#   2  - Circuit breaker triggered
#   3  - Configuration/argument error
#

set -uo pipefail  # Note: not -e, we handle errors explicitly

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_DIR="$SCRIPT_DIR/schemas"
LOG_BASE="logs/batch-$(date +%Y%m%d-%H%M%S)"
STATUS_FILE="status.json"
LOCK_FILE="logs/.batch-orchestrator.lock"

# Timeouts and limits
readonly ISSUE_TIMEOUT=10800  # 180 minutes per issue
readonly MAX_CONSECUTIVE_FAILURES=3
readonly RATE_LIMIT_BUFFER=60  # Extra seconds to wait after rate limit reset
readonly RATE_LIMIT_DEFAULT_WAIT=3600  # Default 1 hour if we can't determine wait time

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

MANIFEST=""
ISSUES=""
BRANCH=""
AGENT=""

usage() {
    echo "Usage: $0 --manifest <path>"
    echo "       $0 --issues \"123,124,125\" --branch \"test\""
    echo "       $0 --manifest <path> --agent patch-engineer"
    echo ""
    echo "Options:"
    echo "  --manifest <path>   Path to manifest.json with issues and branch"
    echo "  --issues <list>     Comma-separated list of issue numbers"
    echo "  --branch <name>     Base branch for PRs"
    echo "  --agent <name>      Agent for implement-issue stage (optional)"
    echo ""
    echo "Available agents:"
    echo "  patch-engineer              Minified JS patches, sed/regex patterns"
    echo "  packaging-specialist        .deb, .rpm, AppImage packaging"
    echo "  electron-linux-specialist   BrowserWindow, Wayland/X11, DBus tray"
    echo "  ci-workflow-architect       GitHub Actions, release automation"
    echo "  bash-script-craftsman       Shell scripts, launcher, build system"
    echo "  (none specified)            Default claude behavior"
    echo ""
    echo "Note: process-pr stage always uses code-reviewer agent"
    exit 3
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --manifest)
            [[ -n "${2:-}" ]] || { echo "ERROR: --manifest requires a value" >&2; exit 3; }
            MANIFEST="$2"
            shift 2
            ;;
        --issues)
            [[ -n "${2:-}" ]] || { echo "ERROR: --issues requires a value" >&2; exit 3; }
            ISSUES="$2"
            shift 2
            ;;
        --branch)
            [[ -n "${2:-}" ]] || { echo "ERROR: --branch requires a value" >&2; exit 3; }
            BRANCH="$2"
            shift 2
            ;;
        --agent)
            [[ -n "${2:-}" ]] || { echo "ERROR: --agent requires a value" >&2; exit 3; }
            AGENT="$2"
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

# Load from manifest if provided
if [[ -n "$MANIFEST" ]]; then
    if [[ ! -f "$MANIFEST" ]]; then
        echo "ERROR: Manifest file not found: $MANIFEST"
        exit 3
    fi
    ISSUES=$(jq -r '.issues | join(",")' "$MANIFEST")
    BRANCH=$(jq -r '.base_branch' "$MANIFEST")
    # Load agent from manifest if not specified on command line
    if [[ -z "$AGENT" ]]; then
        AGENT=$(jq -r '.agent // empty' "$MANIFEST")
    fi
fi

if [[ -z "$ISSUES" || -z "$BRANCH" ]]; then
    echo "ERROR: Must provide --manifest or both --issues and --branch"
    usage
fi

# Convert comma-separated to array
IFS=',' read -ra ISSUE_ARRAY <<< "$ISSUES"

# Load schemas as single-line JSON for CLI
# Note: implement-issue now uses its own orchestrator script with separate schemas
if [[ ! -f "$SCHEMA_DIR/process-pr.json" ]]; then
    echo "ERROR: Schema not found: $SCHEMA_DIR/process-pr.json"
    exit 3
fi

PROCESS_SCHEMA=$(jq -c . "$SCHEMA_DIR/process-pr.json")

# =============================================================================
# LOCKING
# =============================================================================

acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"

    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "ERROR: Another batch is running (PID: $lock_pid)"
            echo "Lock file: $LOCK_FILE"
            echo "If stale, remove manually: rm $LOCK_FILE"
            exit 3
        fi
        echo "Removing stale lock file (PID $lock_pid not running)"
        rm -f "$LOCK_FILE"
    fi

    echo $$ > "$LOCK_FILE"
}

# shellcheck disable=SC2317,SC2329 # Called indirectly via trap
release_lock() {
    if [[ -f "$LOCK_FILE" ]] && [[ "$(cat "$LOCK_FILE" 2>/dev/null)" == "$$" ]]; then
        rm -f "$LOCK_FILE"
    fi
}

trap release_lock EXIT
acquire_lock

# =============================================================================
# LOGGING
# =============================================================================

mkdir -p "$LOG_BASE"
LOG_FILE="$LOG_BASE/orchestrator.log"

log() {
    echo "[$(date -Iseconds)] $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date -Iseconds)] ERROR: $*" | tee -a "$LOG_FILE" >&2
}

# =============================================================================
# STATUS FILE MANAGEMENT
# =============================================================================

init_status() {
    local issues_json="[]"
    for issue in "${ISSUE_ARRAY[@]}"; do
        issues_json=$(echo "$issues_json" | jq --argjson num "$issue" '. + [{
            "number": $num,
            "status": "pending",
            "stage": null,
            "pr": null,
            "session_id": null,
            "error": null,
            "follow_ups": [],
            "started_at": null,
            "completed_at": null
        }]')
    done

    jq -n \
        --arg state "running" \
        --arg branch "$BRANCH" \
        --argjson total "${#ISSUE_ARRAY[@]}" \
        --argjson issues "$issues_json" \
        --arg log_dir "$LOG_BASE" \
        '{
            state: $state,
            base_branch: $branch,
            current_issue: null,
            progress: {
                total: $total,
                completed: 0,
                failed: 0,
                pending: $total,
                in_progress: 0
            },
            issues: $issues,
            rate_limit: {
                waiting: false,
                resume_at: null,
                session_id: null
            },
            last_update: (now | todate),
            log_dir: $log_dir
        }' > "$STATUS_FILE"

    log "Initialized status file: $STATUS_FILE"
}

update_issue_field() {
    local issue_num="$1"
    local field="$2"
    local value="$3"
    local is_json="${4:-false}"

    if [[ "$is_json" == "true" ]]; then
        jq --argjson num "$issue_num" \
           --arg field "$field" \
           --argjson val "$value" \
           '(.issues[] | select(.number == $num))[$field] = $val |
            .last_update = (now | todate)' \
           "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    else
        jq --argjson num "$issue_num" \
           --arg field "$field" \
           --arg val "$value" \
           '(.issues[] | select(.number == $num))[$field] = $val |
            .last_update = (now | todate)' \
           "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    fi
}

update_progress() {
    jq '.progress.completed = ([.issues[] | select(.status == "completed")] | length) |
        .progress.failed = ([.issues[] | select(.status == "failed" or .status == "skipped")] | length) |
        .progress.in_progress = ([.issues[] | select(.status == "in_progress")] | length) |
        .progress.pending = ([.issues[] | select(.status == "pending")] | length) |
        .last_update = (now | todate)' \
        "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

set_current_issue() {
    local issue_num="$1"
    jq --argjson num "$issue_num" '.current_issue = $num | .last_update = (now | todate)' \
        "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

set_rate_limit() {
    local waiting="$1"
    local resume_at="${2:-null}"
    local session_id="${3:-null}"

    if [[ "$resume_at" == "null" || -z "$resume_at" ]]; then
        resume_at="null"
    else
        resume_at="\"$resume_at\""
    fi

    if [[ "$session_id" == "null" || -z "$session_id" ]]; then
        session_id="null"
    else
        session_id="\"$session_id\""
    fi

    jq --argjson waiting "$waiting" \
       --argjson resume "$resume_at" \
       --argjson session "$session_id" \
       '.rate_limit = {waiting: $waiting, resume_at: $resume, session_id: $session} |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

set_state() {
    local state="$1"
    jq --arg state "$state" '.state = $state | .last_update = (now | todate)' \
        "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

# =============================================================================
# RATE LIMIT DETECTION
# =============================================================================

detect_rate_limit() {
    local output="$1"
    local exit_code="${2:-0}"

    # Check structured output first (most reliable)
    local status
    status=$(echo "$output" | jq -r '.structured_output.status // empty' 2>/dev/null)

    # If structured output shows success, definitively NOT rate limited
    if [[ "$status" == "success" || "$status" == "merged" || "$status" == "changes_requested" ]]; then
        return 1
    fi

    # If structured output explicitly says rate_limit
    if [[ "$status" == "rate_limit" ]]; then
        return 0
    fi

    # Only check text patterns if structured output is empty/error (fallback detection)
    # Check result text for rate limit indicators
    local result
    result=$(echo "$output" | jq -r '.result // empty' 2>/dev/null)
    if echo "$result" | grep -qiE 'rate.limit|429|too many requests|quota.exceeded|secondary rate'; then
        return 0
    fi

    # Check raw output only if JSON parsing failed (no valid structured_output)
    # Use word boundaries to avoid matching field names like "rate_limit" in JSON
    if [[ -z "$status" ]]; then
        if echo "$output" | grep -qiE '\brate limit\b|HTTP 429|\btoo many requests\b|quota exceeded'; then
            return 0
        fi
    fi

    return 1
}

extract_wait_time() {
    local output="$1"
    local result
    result=$(echo "$output" | jq -r '.result // empty' 2>/dev/null)

    # Combine result and raw output for searching
    local search_text="$result $output"

    # Try to find retry-after seconds
    local retry_after
    retry_after=$(echo "$search_text" | grep -oiE 'retry.after[^0-9]*([0-9]+)' | grep -oE '[0-9]+' | head -1)
    if [[ -n "$retry_after" ]] && (( retry_after > 0 )); then
        echo "$retry_after"
        return
    fi

    # Try to find "wait X minutes/hours"
    local wait_mins
    wait_mins=$(echo "$search_text" | grep -oiE 'wait[^0-9]*([0-9]+)[^0-9]*min' | grep -oE '[0-9]+' | head -1)
    if [[ -n "$wait_mins" ]] && (( wait_mins > 0 )); then
        echo $((wait_mins * 60))
        return
    fi

    local wait_hours
    wait_hours=$(echo "$search_text" | grep -oiE 'wait[^0-9]*([0-9]+)[^0-9]*hour' | grep -oE '[0-9]+' | head -1)
    if [[ -n "$wait_hours" ]] && (( wait_hours > 0 )); then
        echo $((wait_hours * 3600))
        return
    fi

    # Default to configured wait time
    echo "$RATE_LIMIT_DEFAULT_WAIT"
}

# =============================================================================
# WORKTREE CLEANUP
# =============================================================================

cleanup_worktree() {
    local issue_num="$1"
    local issue_status_file="$2"

    if [[ ! -f "$issue_status_file" ]]; then
        log "No status file for worktree cleanup (issue #$issue_num)"
        return
    fi

    local worktree_path
    worktree_path=$(jq -r '.worktree // empty' "$issue_status_file" 2>/dev/null)

    if [[ -z "$worktree_path" || ! -d "$worktree_path" ]]; then
        log "No worktree to clean up for issue #$issue_num"
        return
    fi

    log "Cleaning up worktree for issue #$issue_num: $worktree_path"

    if git worktree remove "$worktree_path" --force 2>/dev/null; then
        log "Worktree removed: $worktree_path"
    else
        log "Warning: Could not remove worktree $worktree_path (may need manual cleanup)"
    fi

    # Prune stale worktree references
    git worktree prune 2>/dev/null
}

# =============================================================================
# ISSUE PROCESSING
# =============================================================================

process_issue() {
    local issue_num="$1"
    local issue_log="$LOG_BASE/issue-$issue_num.log"

    log "=========================================="
    log "Starting issue #$issue_num"
    log "=========================================="

    set_current_issue "$issue_num"
    update_issue_field "$issue_num" "status" "in_progress"
    update_issue_field "$issue_num" "started_at" "$(date -Iseconds)"
    update_issue_field "$issue_num" "stage" "implement-issue"
    update_progress

    # -------------------------------------------------------------------------
    # IMPLEMENT-ISSUE (via orchestrator script)
    # -------------------------------------------------------------------------
    local issue_status_file="$LOG_BASE/issue-$issue_num-status.json"

    local -a agent_args=()
    if [[ -n "$AGENT" ]]; then
        agent_args=(--agent "$AGENT")
    fi

    log "Running: implement-issue-orchestrator.sh --issue $issue_num --branch $BRANCH ${agent_args[*]}"

    local impl_output
    local impl_exit=0

    impl_output=$("$SCRIPT_DIR/implement-issue-orchestrator.sh" \
        --issue "$issue_num" \
        --branch "$BRANCH" \
        "${agent_args[@]}" \
        --status-file "$issue_status_file" \
        2>&1) || impl_exit=$?

    {
        echo "=== implement-issue output ==="
        echo "$impl_output"
        echo "=== exit code: $impl_exit ==="
    } >> "$issue_log"

    # Parse result from status file
    local impl_status="error"
    local pr_number=""
    local impl_error=""

    if [[ -f "$issue_status_file" ]]; then
        local state
        state=$(jq -r '.state' "$issue_status_file")

        # Map script states to expected values
        case "$state" in
            completed)
                impl_status="success"
                # Extract PR number from stages.pr or from the status file
                pr_number=$(jq -r '.stages.pr.pr_number // empty' "$issue_status_file" 2>/dev/null)
                if [[ -z "$pr_number" ]]; then
                    # Fallback: try to parse from log output
                    pr_number=$(echo "$impl_output" | grep -oE 'PR: #[0-9]+' | grep -oE '[0-9]+' | head -1)
                fi
                ;;
            error|max_iterations_quality|max_iterations_pr_review)
                impl_status="error"
                impl_error="Script exited with state: $state"
                ;;
            *)
                impl_status="error"
                impl_error="Unknown state: $state"
                ;;
        esac
    else
        impl_error="Status file not created"
    fi

    log "implement-issue status: $impl_status, PR: ${pr_number:-none}"

    if [[ "$impl_status" != "success" ]]; then
        log_error "implement-issue failed for #$issue_num: ${impl_error:-unknown error}"
        update_issue_field "$issue_num" "status" "failed"
        update_issue_field "$issue_num" "error" "${impl_error:-implement-issue failed with status: $impl_status}"
        update_progress
        return 1
    fi

    if [[ -z "$pr_number" ]]; then
        log_error "implement-issue succeeded but no PR number found for #$issue_num"
        update_issue_field "$issue_num" "status" "failed"
        update_issue_field "$issue_num" "error" "No PR number in status file or output"
        update_progress
        return 1
    fi
    log "implement-issue complete. PR #$pr_number created"
    update_issue_field "$issue_num" "pr" "$pr_number" "true"
    update_issue_field "$issue_num" "stage" "process-pr"

    # -------------------------------------------------------------------------
    # PROCESS-PR (always uses code-reviewer agent)
    # -------------------------------------------------------------------------
    log "Running: claude -p \"/process-pr $pr_number $issue_num $BRANCH\" --agent code-reviewer --json-schema ..."

    local proc_output
    local proc_exit=0

    proc_output=$(timeout "$ISSUE_TIMEOUT" claude -p "/process-pr $pr_number $issue_num $BRANCH" \
        --agent code-reviewer \
        --dangerously-skip-permissions \
        --output-format json \
        --json-schema "$PROCESS_SCHEMA" \
        2>&1) || proc_exit=$?

    {
        echo "=== process-pr output ==="
        echo "$proc_output"
        echo "=== exit code: $proc_exit ==="
    } >> "$issue_log"

    # Update session ID
    session_id=$(echo "$proc_output" | jq -r '.session_id // empty' 2>/dev/null)
    if [[ -n "$session_id" ]]; then
        update_issue_field "$issue_num" "session_id" "$session_id"
    fi

    # Check for rate limit
    if detect_rate_limit "$proc_output" "$proc_exit"; then
        local wait_time
        wait_time=$(extract_wait_time "$proc_output")
        wait_time=$((wait_time + RATE_LIMIT_BUFFER))
        local resume_at
        resume_at=$(date -Iseconds -d "+${wait_time} seconds" 2>/dev/null || date -v+${wait_time}S -Iseconds 2>/dev/null)

        log "Rate limit hit during process-pr. Waiting ${wait_time}s"
        set_rate_limit "true" "$resume_at" "$session_id"

        sleep "$wait_time"

        set_rate_limit "false" "" ""

        # Resume
        if [[ -n "$session_id" ]]; then
            proc_output=$(timeout "$ISSUE_TIMEOUT" claude -p "please continue" \
                --resume "$session_id" \
                --agent code-reviewer \
                --dangerously-skip-permissions \
                --output-format json \
                --json-schema "$PROCESS_SCHEMA" \
                2>&1) || proc_exit=$?
        else
            proc_output=$(timeout "$ISSUE_TIMEOUT" claude -p "/process-pr $pr_number $issue_num $BRANCH" \
                --agent code-reviewer \
                --dangerously-skip-permissions \
                --output-format json \
                --json-schema "$PROCESS_SCHEMA" \
                2>&1) || proc_exit=$?
        fi

        echo "=== process-pr resume output ===" >> "$issue_log"
        echo "$proc_output" >> "$issue_log"
    fi

    # Check for timeout
    if (( proc_exit == 124 )); then
        log_error "Issue #$issue_num timed out during process-pr (${ISSUE_TIMEOUT}s)"
        update_issue_field "$issue_num" "status" "failed"
        update_issue_field "$issue_num" "error" "Timeout after ${ISSUE_TIMEOUT}s during process-pr"
        update_progress
        return 1
    fi

    # Parse structured output
    local proc_status
    local follow_ups
    local proc_error

    proc_status=$(echo "$proc_output" | jq -r '.structured_output.status // "error"' 2>/dev/null)
    follow_ups=$(echo "$proc_output" | jq -c '.structured_output.follow_up_issues // []' 2>/dev/null)
    proc_error=$(echo "$proc_output" | jq -r '.structured_output.error // empty' 2>/dev/null)

    log "process-pr status: $proc_status"

    case "$proc_status" in
        merged)
            log "Issue #$issue_num completed. PR #$pr_number merged."
            update_issue_field "$issue_num" "status" "completed"
            update_issue_field "$issue_num" "completed_at" "$(date -Iseconds)"
            update_issue_field "$issue_num" "follow_ups" "$follow_ups" "true"
            cleanup_worktree "$issue_num" "$issue_status_file"
            ;;
        changes_requested)
            # process-pr handles re-implementation internally by calling implement-issue again
            # If we get here with changes_requested, it means the re-implementation cycle completed
            log "Issue #$issue_num: changes were requested and addressed"
            update_issue_field "$issue_num" "status" "completed"
            update_issue_field "$issue_num" "completed_at" "$(date -Iseconds)"
            cleanup_worktree "$issue_num" "$issue_status_file"
            ;;
        error|rate_limit|*)
            log_error "process-pr failed for #$issue_num: ${proc_error:-status was $proc_status}"
            update_issue_field "$issue_num" "status" "failed"
            update_issue_field "$issue_num" "error" "${proc_error:-process-pr failed with status: $proc_status}"
            update_progress
            return 1
            ;;
    esac

    update_progress
    return 0
}

# =============================================================================
# MAIN LOOP
# =============================================================================

log "=========================================="
log "Batch Orchestrator Starting"
log "=========================================="
log "Issues: ${ISSUE_ARRAY[*]}"
log "Branch: $BRANCH"
log "Implement agent: ${AGENT:-default}"
log "Process-PR agent: code-reviewer"
log "Log dir: $LOG_BASE"
log "Timeout per issue: ${ISSUE_TIMEOUT}s"
log "Max consecutive failures: $MAX_CONSECUTIVE_FAILURES"

init_status

consecutive_failures=0
exit_code=0

for issue in "${ISSUE_ARRAY[@]}"; do
    # Check idempotency - skip if already completed in a previous run
    current_status=$(jq -r --argjson num "$issue" '.issues[] | select(.number == $num) | .status' "$STATUS_FILE")

    if [[ "$current_status" == "completed" ]]; then
        log "Skipping issue #$issue (already completed)"
        continue
    fi

    if process_issue "$issue"; then
        consecutive_failures=0
        log "Issue #$issue processed successfully"
    else
        consecutive_failures=$((consecutive_failures + 1))
        exit_code=1
        log "Issue #$issue failed. Consecutive failures: $consecutive_failures / $MAX_CONSECUTIVE_FAILURES"

        if (( consecutive_failures >= MAX_CONSECUTIVE_FAILURES )); then
            log_error "CIRCUIT BREAKER: $MAX_CONSECUTIVE_FAILURES consecutive failures. Stopping batch."
            set_state "circuit_breaker"
            exit_code=2
            break
        fi
    fi
done

# Final state
final_failed=$(jq '.progress.failed' "$STATUS_FILE")
if (( exit_code == 2 )); then
    # Circuit breaker already set state
    :
elif (( final_failed > 0 )); then
    set_state "completed_with_errors"
else
    set_state "completed"
fi

log "=========================================="
log "Batch Complete"
log "=========================================="
log "Final state: $(jq -r '.state' "$STATUS_FILE")"
log "Progress: $(jq -c '.progress' "$STATUS_FILE")"

# Write summary
jq '{
    state: .state,
    base_branch: .base_branch,
    progress: .progress,
    issues: [.issues[] | {number, status, pr, follow_ups, error}],
    log_dir: .log_dir,
    completed_at: (now | todate)
}' "$STATUS_FILE" > "$LOG_BASE/summary.json"

log "Summary written to $LOG_BASE/summary.json"

exit $exit_code
