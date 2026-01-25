---
name: lint
description: Run shellcheck and actionlint on shell scripts and GitHub Actions workflows. Use before pushing or when fixing lint issues.
---

Run linting tools on shell scripts and GitHub Actions workflows in this project.

## Your Task

Run the following checks on changed files (relative to main branch):

### 1. Shell Scripts (shellcheck)

```bash
# Find changed shell scripts
changed_scripts=$(git diff --name-only main...HEAD 2>/dev/null | grep -E '\.sh$')

# Run shellcheck on each
for script in $changed_scripts; do
    if [[ -f "$script" ]]; then
        shellcheck -f gcc "$script"
    fi
done
```

### 2. GitHub Actions Workflows (actionlint)

```bash
# Find changed workflow files
changed_workflows=$(git diff --name-only main...HEAD 2>/dev/null | grep -E '\.github/workflows/.*\.ya?ml$')

# Run actionlint on each
for workflow in $changed_workflows; do
    if [[ -f "$workflow" ]]; then
        actionlint "$workflow"
    fi
done
```

## Handling Issues

When lint issues are found:

1. **Fix the issues** - Correct the code to resolve warnings/errors
2. **Only use disable directives as a last resort** - If a warning is a false positive or truly unavoidable, add a disable comment with explanation:
   ```bash
   # shellcheck disable=SC2034  # Variable used by sourcing script
   ```
3. **Report what was fixed** - Summarize the changes made

## Optional Guidance

$ARGUMENTS
