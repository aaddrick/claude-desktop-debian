# Distribution — DEB, RPM, AppImage

Tests covering Ubuntu/DEB-specific install behavior, Fedora/RPM-specific install behavior, AppImage fallback paths, and the auto-update interaction with system package managers. See [`../matrix.md`](../matrix.md) for status.

## S01 — AppImage launches without manual `libfuse2t64` install

**Severity:** Critical (for Ubuntu users)
**Surface:** AppImage runtime / FUSE
**Applies to:** Ubu (and any Ubuntu 24.04+ host)
**Issues:** —

**Steps:**
1. Fresh Ubuntu 24.04 install with default packages only.
2. Download the project AppImage.
3. Make executable and run it.

**Expected:** AppImage runs without first installing `libfuse2t64`. Either the AppImage bundles its own FUSE shim, the `.desktop`/postinst declares the dep, or the launcher gives a clear error pointing at the package name.

**Currently:** Fails on Ubuntu 24.04 with `dlopen(): error loading libfuse.so.2`. Workaround: `sudo apt install libfuse2t64`. Not yet filed.

**Diagnostics on failure:** Full stderr from the AppImage launch, `ldd ./claude-desktop-*.AppImage`, `dpkg -l | grep -i fuse`.

**References:** —

## S02 — `XDG_CURRENT_DESKTOP=ubuntu:GNOME` doesn't break DE detection

**Severity:** Critical
**Surface:** DE detection / patch gate
**Applies to:** Ubu
**Issues:** —

**Steps:**
1. On Ubuntu 24.04 (where `XDG_CURRENT_DESKTOP=ubuntu:GNOME`), launch the app.
2. Inspect launcher log for any DE-detection branches that should fire as GNOME.
3. Audit `scripts/launcher-common.sh` and any DE-gated patches for string-equality checks against `XDG_CURRENT_DESKTOP`.

**Expected:** DE-detection logic handles Ubuntu's colon-separated value. `contains "GNOME"` or splitting on `:` is the safe pattern; `== "GNOME"` would miss Ubuntu.

**Diagnostics on failure:** `echo $XDG_CURRENT_DESKTOP`, the relevant launcher.sh code path, launcher log, the patches that ran or didn't.

**References:** Surfaced via session-capture review.

## S03 — DEB install via APT pulls all required runtime deps

**Severity:** Critical
**Surface:** APT repository / dependency declarations
**Applies to:** Ubu (any DEB-based distro)
**Issues:** [`docs/learnings/apt-worker-architecture.md`](../../learnings/apt-worker-architecture.md)

**Steps:**
1. Add the project's APT repo per the README install instructions.
2. `sudo apt install claude-desktop` on a fresh container/VM.
3. Run `claude-desktop` — first launch should succeed with no further package installs.

**Expected:** All transitive runtime deps are declared in the package and pulled by APT. First launch succeeds without manual `apt install` of any extra package.

**Diagnostics on failure:** `apt-cache depends claude-desktop`, missing-library errors from the launcher, `ldd` against the binary.

**References:** [`docs/learnings/apt-worker-architecture.md`](../../learnings/apt-worker-architecture.md)

## S04 — RPM install via DNF pulls all required runtime deps

**Severity:** Critical
**Surface:** DNF repository / dependency declarations
**Applies to:** KDE-W, KDE-X, GNOME, Sway, i3, Niri (any RPM-based distro)
**Issues:** [`docs/learnings/apt-worker-architecture.md`](../../learnings/apt-worker-architecture.md) *(covers both APT and DNF)*

**Steps:**
1. Add the project's DNF repo per the README.
2. `sudo dnf install claude-desktop` on a fresh container/VM.
3. Run `claude-desktop` — first launch should succeed.

**Expected:** All transitive runtime deps are declared in the RPM and pulled by DNF. First launch succeeds with no further package installs.

**Diagnostics on failure:** `dnf repoquery --requires claude-desktop`, `rpm -qR claude-desktop`, launcher missing-library errors.

**References:** [`docs/learnings/apt-worker-architecture.md`](../../learnings/apt-worker-architecture.md)

## S05 — Doctor recognises dnf-installed package, doesn't false-flag as AppImage

**Severity:** Should
**Surface:** Doctor package-format detection
**Applies to:** KDE-W, KDE-X, GNOME, Sway, i3, Niri
**Issues:** —

**Steps:**
1. On a Fedora/Nobara/RPM-based distro with claude-desktop installed via dnf, run `claude-desktop --doctor`.
2. Look for the install-method line.

**Expected:** Doctor detects rpm install (e.g. via `rpm -qf` against the binary path) and reports it cleanly. No `not found via dpkg (AppImage?)` warning.

**Currently:** Doctor only checks dpkg, so every dnf-installed system gets the misleading WARN. Affects KDE-W, KDE-X, GNOME, Sway, i3, Niri rows ([T13](./launch.md#t13--doctor-reports-correct-package-format)). Not yet filed.

**Diagnostics on failure:** Full `--doctor` output, `rpm -qf $(which claude-desktop)`, the doctor source line that decides the format.

**References:** [T13](./launch.md#t13--doctor-reports-correct-package-format)

## S15 — AppImage extraction (`--appimage-extract`) works as documented fallback

**Severity:** Could
**Surface:** AppImage runtime / FUSE-less fallback
**Applies to:** Any AppImage row
**Issues:** —

**Steps:**
1. On a host without FUSE, run `./claude-desktop-*.AppImage --appimage-extract`.
2. Inspect `squashfs-root/`.
3. Run `squashfs-root/AppRun`.

**Expected:** Extraction completes. `squashfs-root/AppRun` launches the app cleanly without FUSE.

**Diagnostics on failure:** Extraction stderr, `ls squashfs-root/`, AppRun stderr.

**References:** Linked from the runtime error message when FUSE is missing.

## S16 — AppImage mount cleans up on app exit

**Severity:** Should
**Surface:** AppImage mount lifecycle
**Applies to:** Any AppImage row
**Issues:** [CLAUDE.md "Common Gotchas"](https://github.com/aaddrick/claude-desktop-debian/blob/main/CLAUDE.md)

**Steps:**
1. Launch the AppImage. Confirm `mount | grep claude` shows the mount.
2. Quit the app cleanly via tray → Quit (or `Ctrl+Q`).
3. Re-run `mount | grep claude` — mount should be gone.

**Expected:** AppImage's mount at `/tmp/.mount_claude*` is unmounted and the directory removed when all child Electron processes exit. Stale mounts after force-quit are handled by `pkill -9 -f "mount_claude"` per CLAUDE.md but should not be the common case.

**Diagnostics on failure:** `mount | grep claude` after exit, `ls -la /tmp/.mount_claude*`, `pgrep -af claude`, `journalctl -k -n 50` for mount errors.

**References:** [CLAUDE.md "Common Gotchas"](https://github.com/aaddrick/claude-desktop-debian/blob/main/CLAUDE.md)

## S26 — Auto-update is disabled when installed via `apt` / `dnf`

**Severity:** Critical
**Surface:** Auto-update path
**Applies to:** All DEB/RPM rows
**Issues:** —

**Steps:**
1. Install via APT or DNF.
2. Launch the app and let it sit for ~5 minutes.
3. Inspect launcher log + filesystem for any auto-update download attempt.

**Expected:** When installed via the project's APT or DNF repo, the in-app auto-update path is suppressed. The app does not download replacement binaries (which would race the package manager). Updates flow through `apt upgrade` / `dnf upgrade` only. AppImage installs may continue to self-update or punt to the user.

**Diagnostics on failure:** Launcher log, network captures (look for downloads from `releases.anthropic.com` or similar), filesystem changes under `~/.config/Claude/`.

**References:** [`docs/learnings/apt-worker-architecture.md`](../../learnings/apt-worker-architecture.md)
