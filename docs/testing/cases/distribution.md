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

**Code anchors:** `scripts/packaging/appimage.sh:226` (downloads the upstream `appimagetool` AppImage as-is — no FUSE shim or static-mksquashfs bundling), `scripts/launcher-common.sh:64` (AppImage forces `--no-sandbox` "due to FUSE constraints"), `.github/workflows/test-artifacts.yml:47` (CI installs `libfuse2` before running the AppImage — i.e. the runtime hard-depends on libfuse2/libfuse2t64). No postinst dep declaration or user-facing FUSE error message exists.

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

**Code anchors:** `scripts/launcher-common.sh:35-44` (Niri auto-detect lowercases `XDG_CURRENT_DESKTOP` and uses `*niri*` glob — handles colon-separated values), `scripts/patches/quick-window.sh:34-35` and `:117-118` (KDE gate uses `.toLowerCase().includes("kde")` — substring, not equality), `scripts/doctor.sh:304` (purely informational `_info "Desktop: $desktop"`, no branching). No `==` equality checks against `XDG_CURRENT_DESKTOP` exist anywhere in shell or patched JS.

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

**Code anchors:** `scripts/packaging/deb.sh:185-197` (DEBIAN/control file — no `Depends:` field is emitted; relies on bundled Electron + the comment "No external dependencies are required at runtime" at line 183), `scripts/packaging/deb.sh:202-230` (postinst only sets chrome-sandbox suid, no dep-pull). Worker chain serving the package: `worker/src/worker.js:22-31` (`DEB_RE`) and `:33-43` (302 → GitHub Releases).

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

**Code anchors:** `scripts/packaging/rpm.sh:188` (`AutoReqProv: no` — explicitly disables RPM's auto-dep generation; spec declares no `Requires:`), `scripts/packaging/rpm.sh:194-198` (strip + build-id disabled because Electron binaries don't tolerate them — bundled approach). Worker chain: `worker/src/worker.js:28-31` (`RPM_RE`).

## S05 — Doctor recognises dnf-installed package, doesn't false-flag as AppImage

**Severity:** Should
**Surface:** Doctor package-format detection
**Applies to:** KDE-W, KDE-X, GNOME, Sway, i3, Niri
**Issues:** —

**Steps:**
1. On a Fedora/Nobara/RPM-based distro with claude-desktop installed via dnf, run `claude-desktop --doctor`.
2. Look for the install-method line.

**Expected:** Doctor detects rpm install (e.g. via `rpm -qf` against the binary path) and reports it cleanly. No `not found via dpkg (AppImage?)` warning.

**Currently:** Doctor's install-method check is gated on `command -v dpkg-query`, so on RPM-only hosts (no dpkg installed) the block is skipped entirely — no install-method line is printed. On hosts that have *both* `dpkg-query` and an rpm-installed `claude-desktop` (uncommon, e.g. mixed Debian + dnf), the misleading `claude-desktop not found via dpkg (AppImage?)` WARN does fire. Either way, no `rpm -qf` branch exists. Affects KDE-W, KDE-X, GNOME, Sway, i3, Niri rows ([T13](./launch.md#t13--doctor-reports-correct-package-format)). Not yet filed.

**Diagnostics on failure:** Full `--doctor` output, `rpm -qf $(which claude-desktop)`, the doctor source line that decides the format.

**References:** [T13](./launch.md#t13--doctor-reports-correct-package-format)

**Code anchors:** `scripts/doctor.sh:353-362` — install-method check is gated on `command -v dpkg-query`; only runs on Debian-family hosts. Falls through to `_warn 'claude-desktop not found via dpkg (AppImage?)'` only if `dpkg-query` is present but returns empty. On Fedora/RPM hosts (`dpkg-query` absent), the entire block is skipped and **no install-method line is printed at all** — neither the misleading WARN nor a correct `rpm -qf` PASS. The drift is "no detection" rather than "false-flag as AppImage" on dpkg-less systems.

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

**Code anchors:** `scripts/packaging/appimage.sh:282` and `:312` (built with stock `appimagetool`, which always supports `--appimage-extract`), `scripts/packaging/appimage.sh:70-118` (`AppRun` script that lives at `squashfs-root/AppRun` after extraction). CI exercises this path: `tests/test-artifact-appimage.sh:36-44` and `.github/workflows/ci.yml:388` both run `--appimage-extract` and assert `squashfs-root/` exists.

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

**Code anchors:** Mount lifecycle is owned by upstream `appimagetool`'s runtime, not this repo — `scripts/packaging/appimage.sh:282`/`:312` invokes the stock tool with no custom AppRun-side cleanup. `CLAUDE.md:179-183` documents `pkill -9 -f "mount_claude"` as the manual recovery for stale mounts after force-quit. No project-side unmount handler exists; the test asserts upstream behavior, not ours.

## S26 — Auto-update is disabled when installed via `apt` / `dnf`

> **⚠ Missing in build 1.5354.0** — No project-side suppression of upstream auto-update exists; the launcher exports `ELECTRON_FORCE_IS_PACKAGED=true`, which causes upstream's `lii()` gate to return true on Linux and the auto-update tick loop to start. Suppression is "accidental" — it relies on Electron's built-in `autoUpdater` module being unimplemented on Linux (so `setFeedURL`/`checkForUpdates` throw, the `error` listener logs, and no download happens). Tracked at [#567](https://github.com/aaddrick/claude-desktop-debian/issues/567); re-verify after next upstream bump.

**Severity:** Critical
**Surface:** Auto-update path
**Applies to:** All DEB/RPM rows
**Issues:** [#567](https://github.com/aaddrick/claude-desktop-debian/issues/567)

**Steps:**
1. Install via APT or DNF.
2. Launch the app and let it sit for ~5 minutes.
3. Inspect launcher log + filesystem for any auto-update download attempt.

**Expected:** When installed via the project's APT or DNF repo, the in-app auto-update path is suppressed. The app does not download replacement binaries (which would race the package manager). Updates flow through `apt upgrade` / `dnf upgrade` only. AppImage installs may continue to self-update or punt to the user.

**Diagnostics on failure:** Launcher log, network captures (look for downloads from `releases.anthropic.com` or `api.anthropic.com/api/desktop/linux/...`), filesystem changes under `~/.config/Claude/`.

**References:** [`docs/learnings/apt-worker-architecture.md`](../../learnings/apt-worker-architecture.md)

**Code anchors:** `scripts/launcher-common.sh:249` (`export ELECTRON_FORCE_IS_PACKAGED=true` — makes upstream think it's installed); `build-reference/app-extracted/.vite/build/index.js:508761-508769` (upstream `lii()` returns `hA.app.isPackaged` on Linux — passes the gate); `:508554-508559` (only suppression hook is enterprise-policy `disableAutoUpdates`, no Linux/distro carve-out); `:508770-508774` (feed URL `https://api.anthropic.com/api/desktop/linux/<arch>/squirrel/update?...`); `:508800-508803` (calls `hA.autoUpdater.setFeedURL` + `.checkForUpdates()` unconditionally on Linux). No patch in `scripts/patches/*.sh` neutralizes the autoUpdater module or sets `disableAutoUpdates`. AppImage continues to ship update info: `scripts/packaging/appimage.sh:308-309` (`gh-releases-zsync` zsync metadata embedded for releases).
