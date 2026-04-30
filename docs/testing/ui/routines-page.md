# UI — Routines Page

The Routines page hosts the list of scheduled tasks (local and remote), the new-routine form, and per-routine detail views. Related functional tests: [T26](../cases/routines.md#t26--routines-page-renders), [T27](../cases/routines.md#t27--scheduled-task-fires-and-notifies), [T28](../cases/routines.md#t28--scheduled-task-catch-up-after-suspend).

## Routines list

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Routines page link | Code-tab sidebar | Click opens the page ([T26](../cases/routines.md#t26--routines-page-renders)) | — |
| Page header | Top of page | Title "Routines" + description | — |
| **New routine** button | Top-right of page | Click shows Local / Remote selector | — |
| Routines list | Page body | Lists all configured routines | — |
| Per-routine row | List item | Name, schedule summary, last-run timestamp, status indicator | — |
| Run-now icon | Per row, hover-revealed | Click triggers immediate run ([T27](../cases/routines.md#t27--scheduled-task-fires-and-notifies)) | — |
| Pause / resume toggle | Per row | Pauses or resumes scheduled runs without deleting | — |
| Click row | Per row | Opens routine detail page | — |

## New routine form (Local)

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Routine type selector | Top of form | Local / Remote tabs or radio | — |
| **Name** field | Top of form | Required; converted to lowercase kebab-case for filesystem | — |
| **Description** field | Below name | Optional one-liner shown in list | — |
| **Instructions** textarea | Mid-form | Rich textarea for the prompt | — |
| Permission mode picker | Within Instructions area | Same options as session: Ask, Auto accept, Plan, Auto, Bypass | — |
| Model picker | Within Instructions area | Sonnet, Opus, Haiku per plan | — |
| **Working folder** picker | Below Instructions | Required; opens native file chooser | If folder not yet trusted, app prompts to trust |
| **Worktree** toggle | Below folder | When ON, each run gets its own isolated worktree | — |
| **Schedule** preset | Bottom of form | Manual / Hourly / Daily / Weekdays / Weekly | — |
| Time picker | Visible for Daily, Weekdays, Weekly | Defaults to 9:00 AM local | — |
| Day picker | Visible for Weekly only | Day-of-week selector | — |
| **Save** button | Bottom-right | Disabled until required fields filled | — |
| **Cancel** button | Bottom-left | Discards form, returns to list | — |
| Folder-trust prompt | Triggered when folder not trusted | Modal asking to trust the selected folder | Required before save |

## New routine form (Remote)

Per upstream docs, remote routines run on Anthropic-managed cloud infrastructure. The form has additional fields for connectors and trigger types (cron, API, GitHub event). On Linux, the Remote tab should function identically to other platforms.

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| Trigger type selector | Top of form | Schedule / API call / GitHub event | — |
| Connectors picker | Per-routine basis (remote) | Configures connectors at routine creation | — |
| Network access controls | If applicable | Tied to cloud environment config | — |

## Routine detail page

Per upstream docs.

| Element | Location | Expected | Notes |
|---------|----------|----------|-------|
| **Run now** button | Top of page | Starts the task immediately | — |
| Status toggle (Active / Paused) | Top of page | Pauses or resumes without deleting | — |
| **Edit** button | Top of page | Opens the same form populated with current values | — |
| **Delete** button | Top of page (or footer) | Removes routine; archives all sessions it created | Confirmation dialog expected |
| **Review history** section | Page body | Lists every past run with timestamp and status | — |
| Per-history-entry hover | Hover skipped runs | Tooltip explains why skipped (asleep, prior run still running, other concurrent task) | — |
| **Show more** button | Bottom of history | Loads older entries | — |
| **Always allowed** panel | Page body | Lists tools auto-approved for this routine | — |
| Revoke approval | Per-tool entry | Removes the auto-approval | — |

## Failure modes to watch for

| Symptom | Likely cause | Notes |
|---------|--------------|-------|
| Folder-trust modal doesn't appear | Trust state cached incorrectly | Clear `~/.claude/trusted-folders` (or equivalent) and retry |
| Save button never enables | Required fields validation regression | DevTools console |
| Time picker truncates / clips | Modal sizing on small viewports | Resize Settings window to reproduce |
| History tooltips don't render | Tooltip component regression | — |
| Run-now does nothing | Task runner thread not started | Launcher log; `pgrep -af claude` for runner subprocess |
| Routines page blank | Code-tab failure ([T16](../cases/code-tab-foundations.md#t16--code-tab-loads)) cascading | Confirm Code tab itself loads first |
