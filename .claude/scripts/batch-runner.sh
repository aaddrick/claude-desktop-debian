#!/bin/bash
#
# batch-runner.sh
# Executes implement-issue and process-pr for a single issue
# Returns JSON to stdout for handle-issues to parse
#
# Usage: ./batch-runner.sh <issue_number> <base_branch>
#
# Output JSON format:
# {
#   "stage": "implement-issue|process-pr",
#   "status": "success|rate_limit|error",
#   "issue": 123,
#   "pr": 456,
#   "session_id": "...",
#   "retry_after": 3600,
#   "reset_at": "2026-01-29T15:30:00Z",
#   "error": "...",
#   "follow_up_issues": [789, 790]
# }
#
# Exit codes:
#   0  - Success (all stages completed)
#   10 - Rate limit (recoverable, wait and retry)
#   20 - Parse error (PR number extraction failed)
#   30 - Logic error (stage failed, may be recoverable)
#   40 - Fatal error (stop batch, needs human)

set -euo pipefail

ISSUE_NUMBER="${1:?Usage: batch-runner.sh <issue_number> <base_branch>}"
BASE_BRANCH="${2:?Usage: batch-runner.sh <issue_number> <base_branch>}"

# Exit codes for different failure types
EXIT_SUCCESS=0
EXIT_RATE_LIMIT=10
EXIT_PARSE_ERROR=20
EXIT_LOGIC_ERROR=30
EXIT_FATAL=40

LOG_DIR="logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/batch-runner-$(date +%Y%m%d-%H%M%S)-issue-$ISSUE_NUMBER.log"

# Lock file to prevent parallel execution
LOCK_FILE="$LOG_DIR/.handle-issues.lock"

# Acquire lock (fail if already held)
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)

        # Check if lock holder is still running
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "ERROR: Another handle-issues batch is running (PID: $lock_pid)"
            echo "Lock file: $LOCK_FILE"
            echo "If this is stale, remove it manually: rm $LOCK_FILE"
            exit $EXIT_FATAL
        else
            echo "[$(date)] Removing stale lock file (PID $lock_pid not running)" >> "$LOG_FILE"
            rm -f "$LOCK_FILE"
        fi
    fi

    # Create lock with our PID
    echo $$ > "$LOCK_FILE"
    echo "[$(date)] Acquired lock (PID: $$)" >> "$LOG_FILE"
}

# Release lock on exit
release_lock() {
    if [ -f "$LOCK_FILE" ] && [ "$(cat "$LOCK_FILE" 2>/dev/null)" = "$$" ]; then
        rm -f "$LOCK_FILE"
        echo "[$(date)] Released lock" >> "$LOG_FILE"
    fi
}

# Set up trap to release lock on exit
trap release_lock EXIT

# Acquire lock before proceeding
acquire_lock

# Helper: output JSON result
output_json() {
    local stage="$1"
    local status="$2"
    local extra="${3:-}"

    cat <<EOF
{
  "stage": "$stage",
  "status": "$status",
  "issue": $ISSUE_NUMBER,
  "base_branch": "$BASE_BRANCH"$extra
}
EOF
}

# Helper: check for rate limit in output
check_rate_limit() {
    local output="$1"

    # Expanded patterns for reliable rate limit detection
    # Covers: GitHub 403, secondary rate limits, Anthropic API limits
    if echo "$output" | grep -qiE \
        "rate.limit|429|403.*forbidden|secondary.*rate|API rate limit|too many requests|quota.exceeded|retry.after"; then
        # Log which pattern matched for debugging
        local matched_pattern
        matched_pattern=$(echo "$output" | grep -oiE \
            "rate.limit|429|403.*forbidden|secondary.*rate|API rate limit|too many requests|quota.exceeded|retry.after" | head -1)
        echo "[$(date)] Rate limit detected via pattern: $matched_pattern" >> "$LOG_FILE"
        return 0  # Rate limited
    fi
    return 1  # Not rate limited
}

# Helper: extract rate limit info
extract_rate_limit_info() {
    local output="$1"
    local retry_after=""
    local reset_at=""

    # Try to extract retry-after (seconds)
    retry_after=$(echo "$output" | grep -oi "retry.after[^0-9]*\([0-9]*\)" | grep -o "[0-9]*" | head -1 || echo "")

    # Try to extract reset time (RFC3339 or human readable)
    reset_at=$(echo "$output" | grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}" | head -1 || echo "")

    # If no RFC3339, try human readable like "10am"
    if [ -z "$reset_at" ]; then
        reset_at=$(echo "$output" | grep -oi "reset at [^.]*" | head -1 || echo "")
    fi

    echo "$retry_after|$reset_at"
}

# =============================================================================
# STAGE 1: implement-issue
# =============================================================================

echo "[$(date)] Starting implement-issue for #$ISSUE_NUMBER on $BASE_BRANCH" >> "$LOG_FILE"

# Run implement-issue in headless mode, capture output and session ID
IMPLEMENT_OUTPUT=$(mktemp)
IMPLEMENT_SESSION_ID=""

# Execute claude with implement-issue skill
# Correct syntax: claude -p "prompt" --flags
if claude -p "/implement-issue $ISSUE_NUMBER $BASE_BRANCH" \
    --dangerously-skip-permissions \
    --output-format json \
    > "$IMPLEMENT_OUTPUT" 2>&1; then

    IMPLEMENT_STATUS="success"
else
    IMPLEMENT_EXIT_CODE=$?

    # Check if rate limited
    if check_rate_limit "$(cat "$IMPLEMENT_OUTPUT")"; then
        IMPLEMENT_STATUS="rate_limit"
        RATE_INFO=$(extract_rate_limit_info "$(cat "$IMPLEMENT_OUTPUT")")
        RETRY_AFTER=$(echo "$RATE_INFO" | cut -d'|' -f1)
        RESET_AT=$(echo "$RATE_INFO" | cut -d'|' -f2)

        # Try to get session ID from JSON output
        IMPLEMENT_SESSION_ID=$(jq -r '.session_id // empty' "$IMPLEMENT_OUTPUT" 2>&1)
        JQ_EXIT=$?
        if [ $JQ_EXIT -ne 0 ]; then
            echo "[$(date)] WARNING: Failed to parse session_id from implement-issue output (jq exit: $JQ_EXIT): $IMPLEMENT_SESSION_ID" >> "$LOG_FILE"
            IMPLEMENT_SESSION_ID=""
        fi

        echo "[$(date)] Rate limited during implement-issue. Retry after: $RETRY_AFTER, Reset at: $RESET_AT" >> "$LOG_FILE"

        output_json "implement-issue" "rate_limit" ",
  \"session_id\": \"$IMPLEMENT_SESSION_ID\",
  \"retry_after\": ${RETRY_AFTER:-null},
  \"reset_at\": \"${RESET_AT:-}\",
  \"error\": \"Rate limit exceeded\""

        rm -f "$IMPLEMENT_OUTPUT"
        exit $EXIT_RATE_LIMIT
    else
        IMPLEMENT_STATUS="error"
        # Capture full error but limit to 2000 chars for JSON safety
        ERROR_MSG=$(cat "$IMPLEMENT_OUTPUT" | tr '\n' ' ' | sed 's/"/\\"/g' | cut -c1-2000)
        if [ ${#ERROR_MSG} -eq 2000 ]; then
            ERROR_MSG="${ERROR_MSG}... [truncated, see log file]"
        fi
        IMPLEMENT_SESSION_ID=$(jq -r '.session_id // empty' "$IMPLEMENT_OUTPUT" 2>&1)
        JQ_EXIT=$?
        if [ $JQ_EXIT -ne 0 ]; then
            echo "[$(date)] WARNING: Failed to parse session_id from implement-issue output (jq exit: $JQ_EXIT): $IMPLEMENT_SESSION_ID" >> "$LOG_FILE"
            IMPLEMENT_SESSION_ID=""
        fi

        echo "[$(date)] Error during implement-issue: $ERROR_MSG" >> "$LOG_FILE"

        output_json "implement-issue" "error" ",
  \"session_id\": \"$IMPLEMENT_SESSION_ID\",
  \"error\": \"$ERROR_MSG\""

        rm -f "$IMPLEMENT_OUTPUT"
        exit $EXIT_LOGIC_ERROR
    fi
fi

# Extract PR number from successful implement-issue output
PR_NUMBER=$(grep -oE "github\.com/[^/]+/[^/]+/pull/([0-9]+)" "$IMPLEMENT_OUTPUT" | grep -oE "[0-9]+$" | head -1 || echo "")

# Fallback: If regex parsing fails, query GitHub directly
if [ -z "$PR_NUMBER" ]; then
    echo "[$(date)] PR number not found in output, trying GitHub fallback query..." >> "$LOG_FILE"

    # Search for open PRs with exact issue number in title (word boundary via regex)
    REPO=$(git remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[:/]##; s/\.git$//')
    PR_NUMBER=$(gh pr list --repo "$REPO" --state open \
        --json number,title \
        --jq ".[] | select(.title | test(\"issue-${ISSUE_NUMBER}[^0-9]\") or test(\"issue-${ISSUE_NUMBER}\$\")) | .number" \
        2>/dev/null | head -1 || echo "")

    if [ -n "$PR_NUMBER" ]; then
        echo "[$(date)] Found PR #$PR_NUMBER via GitHub fallback query" >> "$LOG_FILE"
    fi
fi

if [ -z "$PR_NUMBER" ]; then
    echo "[$(date)] implement-issue completed but no PR number found (regex and fallback failed)" >> "$LOG_FILE"
    output_json "implement-issue" "error" ",
  \"error\": \"No PR number found in output\""
    rm -f "$IMPLEMENT_OUTPUT"
    exit $EXIT_PARSE_ERROR
fi

echo "[$(date)] implement-issue completed. PR #$PR_NUMBER created" >> "$LOG_FILE"
cat "$IMPLEMENT_OUTPUT" >> "$LOG_FILE"
rm -f "$IMPLEMENT_OUTPUT"

# =============================================================================
# STAGE 2: process-pr
# =============================================================================

echo "[$(date)] Starting process-pr for PR #$PR_NUMBER, Issue #$ISSUE_NUMBER" >> "$LOG_FILE"

PROCESS_OUTPUT=$(mktemp)
PROCESS_SESSION_ID=""

if claude -p "/process-pr $PR_NUMBER $ISSUE_NUMBER $BASE_BRANCH" \
    --dangerously-skip-permissions \
    --output-format json \
    > "$PROCESS_OUTPUT" 2>&1; then

    PROCESS_STATUS="success"

    # Check if it was approved or changes requested
    if grep -qi "changes.requested\|re-implementing" "$PROCESS_OUTPUT"; then
        PROCESS_STATUS="changes_requested"
    elif grep -qi "approved\|merged" "$PROCESS_OUTPUT"; then
        PROCESS_STATUS="approved"
    fi
else
    PROCESS_EXIT_CODE=$?

    # Check if rate limited
    if check_rate_limit "$(cat "$PROCESS_OUTPUT")"; then
        PROCESS_STATUS="rate_limit"
        RATE_INFO=$(extract_rate_limit_info "$(cat "$PROCESS_OUTPUT")")
        RETRY_AFTER=$(echo "$RATE_INFO" | cut -d'|' -f1)
        RESET_AT=$(echo "$RATE_INFO" | cut -d'|' -f2)

        PROCESS_SESSION_ID=$(jq -r '.session_id // empty' "$PROCESS_OUTPUT" 2>&1)
        JQ_EXIT=$?
        if [ $JQ_EXIT -ne 0 ]; then
            echo "[$(date)] WARNING: Failed to parse session_id from process-pr output (jq exit: $JQ_EXIT): $PROCESS_SESSION_ID" >> "$LOG_FILE"
            PROCESS_SESSION_ID=""
        fi

        echo "[$(date)] Rate limited during process-pr. Retry after: $RETRY_AFTER, Reset at: $RESET_AT" >> "$LOG_FILE"

        output_json "process-pr" "rate_limit" ",
  \"pr\": $PR_NUMBER,
  \"session_id\": \"$PROCESS_SESSION_ID\",
  \"retry_after\": ${RETRY_AFTER:-null},
  \"reset_at\": \"${RESET_AT:-}\",
  \"error\": \"Rate limit exceeded\""

        rm -f "$PROCESS_OUTPUT"
        exit $EXIT_RATE_LIMIT
    else
        PROCESS_STATUS="error"
        # Capture full error but limit to 2000 chars for JSON safety
        ERROR_MSG=$(cat "$PROCESS_OUTPUT" | tr '\n' ' ' | sed 's/"/\\"/g' | cut -c1-2000)
        if [ ${#ERROR_MSG} -eq 2000 ]; then
            ERROR_MSG="${ERROR_MSG}... [truncated, see log file]"
        fi
        PROCESS_SESSION_ID=$(jq -r '.session_id // empty' "$PROCESS_OUTPUT" 2>&1)
        JQ_EXIT=$?
        if [ $JQ_EXIT -ne 0 ]; then
            echo "[$(date)] WARNING: Failed to parse session_id from process-pr output (jq exit: $JQ_EXIT): $PROCESS_SESSION_ID" >> "$LOG_FILE"
            PROCESS_SESSION_ID=""
        fi

        echo "[$(date)] Error during process-pr: $ERROR_MSG" >> "$LOG_FILE"

        output_json "process-pr" "error" ",
  \"pr\": $PR_NUMBER,
  \"session_id\": \"$PROCESS_SESSION_ID\",
  \"error\": \"$ERROR_MSG\""

        rm -f "$PROCESS_OUTPUT"
        exit $EXIT_LOGIC_ERROR
    fi
fi

# Extract follow-up issues if any
FOLLOW_UP_ISSUES=$(grep -oE "Created follow-up issue #[0-9]+" "$PROCESS_OUTPUT" | grep -oE "[0-9]+" | tr '\n' ',' | sed 's/,$//' || echo "")

echo "[$(date)] process-pr completed with status: $PROCESS_STATUS" >> "$LOG_FILE"
cat "$PROCESS_OUTPUT" >> "$LOG_FILE"
rm -f "$PROCESS_OUTPUT"

# =============================================================================
# OUTPUT FINAL RESULT
# =============================================================================

FOLLOW_UP_JSON="[]"
if [ -n "$FOLLOW_UP_ISSUES" ]; then
    FOLLOW_UP_JSON="[$FOLLOW_UP_ISSUES]"
fi

output_json "process-pr" "$PROCESS_STATUS" ",
  \"pr\": $PR_NUMBER,
  \"follow_up_issues\": $FOLLOW_UP_JSON"

echo "[$(date)] batch-runner completed for issue #$ISSUE_NUMBER" >> "$LOG_FILE"
