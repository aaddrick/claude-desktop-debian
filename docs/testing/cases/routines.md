# Routines & Scheduled Tasks

Tests covering the Routines page, scheduled task firing, catch-up runs after suspend, and the suspend-inhibit toggle. See [`../matrix.md`](../matrix.md) for status.

## T26 — Routines page renders

**Severity:** Critical
**Surface:** Routines page
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Sign into the app, open the Code tab.
2. Click **Routines** in the sidebar.
3. Click **New routine** → **Local**.

**Expected:** Routines list opens. New-routine form shows all schedule presets (Manual, Hourly, Daily, Weekdays, Weekly), permission-mode picker, model picker, working-folder picker, and worktree toggle.

**Diagnostics on failure:** Screenshot of the Routines page (or the failure state), DevTools console output, launcher log, network captures of the routines API call (`mitmproxy` or DevTools network panel).

**References:** [Schedule recurring tasks](https://code.claude.com/docs/en/desktop-scheduled-tasks)

## T27 — Scheduled task fires and notifies

**Severity:** Critical
**Surface:** Routines runtime + libnotify
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Create a Manual task with a simple instruction (e.g. "echo hello").
2. Click **Run now**. Observe.
3. Optionally: create an Hourly task and verify across the next hour boundary.

**Expected:** A fresh session starts, appears in the **Scheduled** section of the sidebar, and posts a desktop notification when it begins. Subsequent runs respect the deterministic offset described in upstream docs.

**Diagnostics on failure:** Launcher log, screenshot of sidebar, `gdbus call --session --dest=org.freedesktop.Notifications --object-path=/org/freedesktop/Notifications --method=org.freedesktop.DBus.Introspectable.Introspect` (verify daemon present), task SKILL.md content under `~/.claude/scheduled-tasks/<task-name>/`.

**References:** [How scheduled tasks run](https://code.claude.com/docs/en/desktop-scheduled-tasks#how-scheduled-tasks-run)

## T28 — Scheduled task catch-up after suspend

**Severity:** Should
**Surface:** Routines runtime / wake-from-suspend
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Create an Hourly task.
2. Suspend the host (`systemctl suspend`).
3. Wait past at least one hourly slot. Wake the host.
4. Observe whether a catch-up run starts.

**Expected:** Exactly one catch-up run for the most recently missed slot (older missed slots are discarded). Notification announces the catch-up. Missed runs older than seven days are not retried.

**Diagnostics on failure:** Task history in the routines detail page, launcher log, `journalctl --since="-1 day" | grep -i suspend`.

**References:** [Missed runs](https://code.claude.com/docs/en/desktop-scheduled-tasks#missed-runs)

## S19 — `CLAUDE_CONFIG_DIR` redirects scheduled-task storage

**Severity:** Could
**Surface:** Config dir env var
**Applies to:** All rows
**Issues:** —

**Steps:**
1. In the local environment editor, set `CLAUDE_CONFIG_DIR=/some/other/path`.
2. Restart the app.
3. Create a scheduled task. Inspect filesystem.

**Expected:** Tasks resolve under `${CLAUDE_CONFIG_DIR}/scheduled-tasks/<task-name>/SKILL.md` rather than `~/.claude/scheduled-tasks/`. Pre-existing tasks under the old path are not silently dropped.

**Diagnostics on failure:** `ls -la ${CLAUDE_CONFIG_DIR}/scheduled-tasks/` and `~/.claude/scheduled-tasks/`, launcher log, env dump.

**References:** [Manage scheduled tasks](https://code.claude.com/docs/en/desktop-scheduled-tasks#manage-scheduled-tasks)

## S20 — "Keep computer awake" inhibits idle suspend

**Severity:** Should
**Surface:** Suspend inhibitor
**Applies to:** All rows
**Issues:** —

**Steps:**
1. Open Settings → Desktop app → General → "Keep computer awake". Toggle ON.
2. Run `systemd-inhibit --list`. Look for a Claude-owned lock with `idle:sleep` what.
3. Toggle OFF. Re-run `systemd-inhibit --list` — lock should be gone.

**Expected:** Toggling ON registers `systemd-inhibit --what=idle:sleep` (or the `org.freedesktop.PowerManagement.Inhibit` DBus call). Toggling OFF releases the lock.

**Diagnostics on failure:** `systemd-inhibit --list` before/after, `busctl --user tree org.freedesktop.PowerManagement` (if the path uses that backend), launcher log, the relevant settings IPC call.

**References:** [How scheduled tasks run](https://code.claude.com/docs/en/desktop-scheduled-tasks#how-scheduled-tasks-run)

## S21 — Lid-close still suspends per OS policy

**Severity:** Critical
**Surface:** Suspend inhibitor scope
**Applies to:** All rows (laptop hosts)
**Issues:** —

**Steps:**
1. With "Keep computer awake" ON, close the laptop lid.
2. Observe whether the machine suspends.

**Expected:** Machine still suspends per logind's `HandleLidSwitch=suspend`. The inhibit lock taken in [S20](#s20--keep-computer-awake-inhibits-idle-suspend) targets `idle:sleep`, not `handle-lid-switch`, so lid-close behavior is unaffected.

**Diagnostics on failure:** `loginctl show-session --property=HandleLidSwitch`, `journalctl --since="-5 minutes"`, the actual `--what=` flags on the Claude-owned inhibitor.

**References:** [How scheduled tasks run](https://code.claude.com/docs/en/desktop-scheduled-tasks#how-scheduled-tasks-run)
