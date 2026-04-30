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

## T02 — Doctor health check

**Severity:** Critical
**Surface:** CLI / `--doctor`
**Applies to:** All rows
**Issues:** [PR #538](https://github.com/aaddrick/claude-desktop-debian/pull/538)

**Steps:**
1. Run `claude-desktop --doctor`.
2. Inspect exit code (`echo $?`) and stdout/stderr.

**Expected:** Exits 0. All checks PASS or report expected WARN. No FAIL checks. Resolved titlebar style is `hybrid` on PR #538 builds; legacy builds report whichever style they were built with. See also [T13](#t13--doctor-reports-correct-package-format) for the package-format detection slice.

**Diagnostics on failure:** Full `--doctor` output, the install path being inspected (`which claude-desktop`), package metadata (`dpkg -S` / `rpm -qf` against the binary).

**References:** [PR #538](https://github.com/aaddrick/claude-desktop-debian/pull/538)

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

## T14 — Multi-instance behavior

**Severity:** Critical
**Surface:** App lifecycle
**Applies to:** All rows
**Issues:** [PR #536](https://github.com/aaddrick/claude-desktop-debian/pull/536)

**Steps:**
1. Launch `claude-desktop`. Wait for the main window.
2. Launch `claude-desktop` again from another terminal or `.desktop` invocation.
3. Optionally: launch with a second profile (per PR #536 opt-in flag).

**Expected:** Second invocation focuses the existing window — no new process. With profile-based multi-instance opted in (PR #536), each profile routes to its own instance.

**Diagnostics on failure:** `pgrep -af claude-desktop`, `ls -la ~/.config/Claude/SingletonLock`, launcher log, any "another instance is running" dialog text.

**References:** [PR #536](https://github.com/aaddrick/claude-desktop-debian/pull/536)
