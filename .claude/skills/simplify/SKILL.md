---
name: simplify
description: Manually trigger the cdd-code-simplifier agent to review and simplify code
disable-model-invocation: true
---

Run the cdd-code-simplifier agent to review and simplify code for clarity, consistency, and maintainability.

## Your Task

Use the Task tool with `subagent_type: "cdd-code-simplifier"` to run the code simplifier.

**Scope determination:**

1. If guidance was provided after `/simplify`, pass it to the agent as part of the prompt
2. If no guidance provided, have the agent focus on recently modified files (use `git diff --name-only main...HEAD` or `git status` to identify them)

**User guidance:** $ARGUMENTS

**After the agent completes:**

1. Review the changes made
2. If changes were made, ask if the user wants to commit them
3. Provide a brief summary of what was simplified

## Examples

- `/simplify` - Simplify recently modified files
- `/simplify focus on build.sh error handling` - Simplify with specific guidance
- `/simplify only look at the new functions I added` - Narrow the scope
