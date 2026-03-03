---
name: triage
description: Trigger the issue triage workflow for a specific issue. Usage: /triage {issue_number}
---

Trigger the automated issue triage GitHub Actions workflow for the specified issue.

## Your Task

Trigger the `Issue Triage` workflow via `workflow_dispatch` for issue number `$ARGUMENTS`.

### Steps

1. **Validate the issue number**

```bash
# Check the argument is a number
issue_number="$ARGUMENTS"
if ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
    echo "Error: provide an issue number, e.g. /triage 275"
    exit 1
fi

# Verify the issue exists
gh issue view "$issue_number" --json number,title,state,labels --jq '"#\(.number): \(.title) [\(.state)]"'
```

2. **Check current triage state**

Check if the issue already has a triage label. If so, inform the user and ask whether to re-triage (which requires removing the existing triage label first).

3. **Remove existing triage labels if re-triaging**

```bash
for label in "triage: investigated" "triage: needs-info" "triage: duplicate" "triage: not-actionable" "triage: needs-human"; do
    gh issue edit "$issue_number" --remove-label "$label" 2>/dev/null || true
done
```

4. **Trigger the workflow**

```bash
gh workflow run "Issue Triage" -f issue_number="$issue_number"
```

5. **Monitor the run**

```bash
# Wait for the run to appear
sleep 5
run_id=$(gh run list --workflow issue-triage.yml --limit 1 --json databaseId --jq '.[0].databaseId')
echo "Workflow run: https://github.com/aaddrick/claude-desktop-debian/actions/runs/$run_id"

# Watch it
gh run watch "$run_id"
```

6. **Show results**

After the run completes, show the issue's updated labels and the latest comment:

```bash
gh issue view "$issue_number" --json labels --jq '[.labels[].name]'
gh issue view "$issue_number" --json comments --jq '.comments[-1].body'
```
