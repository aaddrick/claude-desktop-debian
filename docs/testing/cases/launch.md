# Launch & Process Lifecycle

Tests covering app startup, the `--doctor` health check, package-format detection, and multi-instance behavior. See [`../matrix.md`](../matrix.md) for status.

## T01 — App launch

**Severity:** Smoke
**Surface:** App startup
**Applies to:** All rows
**Issues:** —
**Runner:** [`tools/test-harness/src/runners/T01_app_launch.spec.ts`](../../../tools/test-harness/src/runners/T01_app_launch.spec.ts)

**Steps:**
1. From a clean session, run `claude-desktop` (deb/rpm) or launch the AppImage.
2. Wait up to 10 seconds.

**Expected:** Main window opens within ~10s. No error toast, no crash. The launcher log at `~/.cache/claude-desktop-debian/launcher.log` shows the expected backend selection (`Using X11 backend via XWayland` on Wayland sessions, or native Wayland when forced).

**Diagnostics on failure:** Launcher log, `--doctor` output, session env (`XDG_SESSION_TYPE`, `XDG_CURRENT_DESKTOP`), `dmesg | tail -50`, any crash report under `~/.config/Claude/logs/`.

**References:** —
**Code anchors:** `scripts/launcher-common.sh:98` (X11-via-XWayland log line), `scripts/launcher-common.sh:102` (native-Wayland log line), `build-reference/app-extracted/.vite/build/index.js:524875` (`app.on("ready")` registration), `build-reference/app-extracted/.vite/build/index.js:524881-524931` (main `BrowserWindow` factory `Ori()` — `titleBarStyle`, mainWindow.js preload, initial `show`).

## T02 — Doctor health check

**Severity:** Critical
**Surface:** CLI / `--doctor`
**Applies to:** All rows
**Issues:** [PR #538](https://github.com/aaddrick/claude-desktop-debian/pull/538)

**Steps:**
1. Run `claude-desktop --doctor`.
2. Inspect exit code (`echo $?`) and stdout/stderr.

**Expected:** Exits 0. All checks PASS or report expected WARN. No FAIL checks. Doctor currently reports display-server, menu-bar mode, Electron path/version, Chrome sandbox perms, SingletonLock, MCP config, Node.js, desktop entry, disk space, and a Cowork section — it does **not** surface the resolved titlebar style. See also [T13](#t13--doctor-reports-correct-package-format) for the package-format detection slice.

**Diagnostics on failure:** Full `--doctor` output, the install path being inspected (`which claude-desktop`), package metadata (`dpkg -S` / `rpm -qf` against the binary).

**References:** [PR #538](https://github.com/aaddrick/claude-desktop-debian/pull/538)
**Code anchors:** `scripts/doctor.sh:280` (`run_doctor` entry point), `scripts/doctor.sh:301-319` (display-server check), `scripts/doctor.sh:401-417` (SingletonLock check), `scripts/doctor.sh:744-753` (exit-code summary).

## T13 — Doctor reports correct package format

**Severity:** Should
**Surface:** CLI / `--doctor`
**Applies to:** All rows (currently `✗` on every Fedora row — see [S05](./distribution.md#s05--doctor-recognises-dnf-installed-package-doesnt-false-flag-as-appimage))
**Issues:** — *(no issue filed; surfaced via session-capture review)*

**Steps:**
1. Install via the relevant package manager (`apt` / `dnf`) or AppImage.
2. Run `claude-desktop --doctor` and look for the install-method line.

**Expected:** Doctor identifies the install method correctly. On RPM-based distros (Fedora, Nobara) it does **not** report `not found via dpkg (AppImage?)` — that warning currently false-flags every dnf install. On DEB-based distros it does not assume AppImage when dpkg returns the package metadata.

**Diagnostics on failure:** `dpkg -S $(which claude-desktop)`, `rpm -qf $(which claude-desktop)`, full `--doctor` output, the line of doctor source that decides the format.

**References:** [S05](./distribution.md#s05--doctor-recognises-dnf-installed-package-doesnt-false-flag-as-appimage)
**Code anchors:** `scripts/doctor.sh:353-362` — version probe is dpkg-only (`dpkg-query -W -f='${Version}' claude-desktop`); on RPM/AppImage hosts that lack `dpkg-query` the block is skipped, but on a Fedora host that *does* have `dpkg-query` installed (e.g. for cross-distro tooling) the `_warn 'claude-desktop not found via dpkg (AppImage?)'` branch fires for any dnf-installed copy. There is no corresponding `rpm -qf` / `rpm -q claude-desktop` branch.

## T14 — Multi-instance behavior

**Severity:** Critical
**Surface:** App lifecycle
**Applies to:** All rows
**Issues:** [PR #536](https://github.com/aaddrick/claude-desktop-debian/pull/536) (closed, docs-only — no in-tree opt-in flag)

**Steps:**
1. Launch `claude-desktop`. Wait for the main window.
2. Launch `claude-desktop` again from another terminal or `.desktop` invocation.
3. Optionally: follow the manual `--user-data-dir` recipe sketched in PR #536 (separate Electron `userData` per profile so each gets its own `SingletonLock` — note the PR was closed, the recipe is not shipped in-tree).

**Expected:** Second invocation focuses the existing window — no new process. The launcher's `cleanup_stale_lock` removes a `SingletonLock` whose owning PID is no longer running. With separate `--user-data-dir` per profile (manual workaround, not an in-tree feature), each profile runs an independent Electron instance.

**Diagnostics on failure:** `pgrep -af claude-desktop`, `ls -la ~/.config/Claude/SingletonLock`, launcher log, any "another instance is running" dialog text.

**References:** [PR #536](https://github.com/aaddrick/claude-desktop-debian/pull/536)
**Code anchors:** `build-reference/app-extracted/.vite/build/index.js:525162-525173` (`requestSingleInstanceLock()` + `app.on("second-instance", ...)` — shows existing window, restores if minimized, focuses), `build-reference/app-extracted/.vite/build/index.js:525204-525207` (early-return on lost lock at `app.on("ready")`), `scripts/launcher-common.sh:187-208` (`cleanup_stale_lock` — drops a `SingletonLock` symlink whose `hostname-PID` target points at a dead PID).
