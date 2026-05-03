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

**Code anchors:** `build-reference/app-extracted/.vite/build/index.js:507710` (create payload — `permissionMode`, `model`, `userSelectedFolders`, `useWorktree`, `cronExpression`, `fireAt`); `build-reference/app-extracted/.vite/build/index.js:280299` (`@hourly: "0 * * * *"` preset)

**Inventory anchors:** `root.complementary.button-by-name.routines` (sidebar entry); `root.complementary.button-by-name.routines.main.region.button-by-name.new-routine` (form trigger); siblings `…button-by-name.all`, `…button-by-name.calendar` (list-view tabs). Preset list (Hourly/Daily/etc.) lives inside the New-routine modal and is not in the idle-state inventory — re-capture with the modal open to anchor.

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

**Code anchors:** `build-reference/app-extracted/.vite/build/index.js:282332` (`runNow(A)` — manual dispatch); `build-reference/app-extracted/.vite/build/index.js:512837` (`Rc.showNotification(...,scheduled-${l},...)` — desktop notification on completion); `build-reference/app-extracted/.vite/build/index.js:282654` (`getJitterSecondsForTask` — deterministic per-task offset via `v2r(A, n*60)`, capped by `dispatchJitterMaxMinutes` default 10)

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

**Code anchors:** `build-reference/app-extracted/.vite/build/index.js:281695` (`R2r` — walks back from now, capped at `10080 * 60 * 1e3` ms = 7 days, returns at most one missed slot, dedupes by `IfA` bucket-key); `build-reference/app-extracted/.vite/build/index.js:281942` (`scheduledTaskPostWakeDelayMs` default 60000 ms — gates dispatch after `powerMonitor.on("resume")`); `build-reference/app-extracted/.vite/build/index.js:282569` (catch-up branch: `c ? 0 : this.getJitterSecondsForTask(o.id)` — missed-slot dispatch skips jitter)

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

**Code anchors:** `build-reference/app-extracted/.vite/build/index.js:283108` (`cE()` — resolves `process.env.CLAUDE_CONFIG_DIR ?? ~/.claude`, handles `~` prefix); `build-reference/app-extracted/.vite/build/index.js:283118` (`Tce()` — returns `${cE()}/scheduled-tasks`); `build-reference/app-extracted/.vite/build/index.js:488317` and `:509032` (call sites passing `taskFilesDir: Tce()` into the scheduled-tasks substrate)

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

**Code anchors:** `build-reference/app-extracted/.vite/build/index.js:241897` (`hA.powerSaveBlocker.start("prevent-app-suspension")` — single block call, ref-counted by `PhA` Set); `build-reference/app-extracted/.vite/build/index.js:241905` (`hA.powerSaveBlocker.stop(BP)` when last claim drops); `build-reference/app-extracted/.vite/build/index.js:241909` (settings binding: `PHe = "keepAwakeEnabled"`); `build-reference/app-extracted/.vite/build/index.js:241914` (`vy.on("keepAwakeEnabled", YHe)` — toggle observer)

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

**Code anchors:** `build-reference/app-extracted/.vite/build/index.js:241897` (only `"prevent-app-suspension"` is passed to `powerSaveBlocker.start` — Electron maps this to `idle:sleep`); no `handle-lid-switch` / `HandleLidSwitch` token anywhere in `index.js` (verified via `grep -nE 'lid|HandleLidSwitch|handle-lid' index.js`)
