#!/usr/bin/env bash
# Shared helpers for artifact validation tests

# _resolve_asar lives in the build's own common utilities so the audit
# tool, the patch-stage harness and these artifact tests all share one
# resolver instead of three copies. Resolve the path from this file
# rather than a caller's, since each entrypoint sources us by its own
# $script_dir.
_artifact_common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_common.sh
source "$_artifact_common_dir/../scripts/_common.sh" || {
	echo "Cannot source scripts/_common.sh from $_artifact_common_dir" >&2
	exit 1
}

_pass_count=0
_fail_count=0

pass() {
	printf '[PASS] %s\n' "$*"
	((_pass_count++))
}

fail() {
	printf '[FAIL] %s\n' "$*" >&2
	((_fail_count++))
}

assert_file_exists() {
	if [[ -f $1 ]]; then
		pass "File exists: $1"
	else
		fail "File missing: $1"
	fi
}

assert_dir_exists() {
	if [[ -d $1 ]]; then
		pass "Directory exists: $1"
	else
		fail "Directory missing: $1"
	fi
}

assert_executable() {
	if [[ -x $1 ]]; then
		pass "Executable: $1"
	else
		fail "Not executable: $1"
	fi
}

assert_setuid() {
	local path="$1" desc="${2:-}"
	if [[ -u $path ]]; then
		pass "${desc:-"Setuid bit set: $path"}"
	else
		fail "${desc:-"Setuid bit not set: $path"}"
	fi
}

assert_contains() {
	local file="$1" pattern="$2" desc="${3:-}"
	if grep -q "$pattern" "$file" 2>/dev/null; then
		pass "${desc:-"$file contains '$pattern'"}"
	else
		fail "${desc:-"$file does not contain '$pattern'"}"
	fi
}

assert_command_succeeds() {
	local desc="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		pass "$desc"
	else
		fail "$desc (exit code: $?)"
	fi
}

# Validate app contents inside an Electron resources directory.
# Since the v3.0.0 patch-zero rebase the asar is the OFFICIAL bundle
# (byte-identical unless a survivor patch ran), so this asserts the
# upstream shape — no frame-fix files, no injected desktopName, no
# stubbed claude-native. See docs/decisions.md D-002.
# $1 = path to the resources/ dir containing app.asar
# $2 = (optional) path to the installed .desktop file; when given and
#      the asar could be extracted, StartupWMClass is checked against
#      the package.json desktopName it must be derived from (#779)
validate_app_contents() {
	local resources_dir="$1"
	local desktop_file="${2:-}"

	assert_file_exists "$resources_dir/app.asar"
	assert_dir_exists "$resources_dir/app.asar.unpacked"

	# Official unpacked set: the real Rust native binding plus the
	# node-pty prebuild (arch-dependent subdir, hence find). The 2.x
	# unpacked stubs are gone by design; cowork-vm-service.js returned
	# in #776 but lives at the resources/ root (asserted below), never
	# in app.asar.unpacked.
	local native_binding pty_prebuild
	native_binding=$(find "$resources_dir/app.asar.unpacked" \
		-name 'claude-native-binding.node' -type f | head -1)
	if [[ -n $native_binding ]]; then
		pass 'Unpacked: claude-native-binding.node present'
	else
		fail 'Unpacked: claude-native-binding.node missing'
	fi
	pty_prebuild=$(find "$resources_dir/app.asar.unpacked" \
		-name 'pty.node' -type f | head -1)
	if [[ -n $pty_prebuild ]]; then
		pass 'Unpacked: node-pty prebuild present'
	else
		fail 'Unpacked: node-pty prebuild missing'
	fi

	# Cowork's bundled virtiofsd: the #771 un-gate patch makes it the
	# universal fallback, and the client resolves it with X_OK — a
	# repack that drops the exec bit silently kills Cowork on every
	# host without a client-probed system virtiofsd (the mode-loss
	# trap in docs/learnings/packaging-permissions.md).
	if [[ -x $resources_dir/virtiofsd ]]; then
		pass 'Bundled virtiofsd present and executable'
	elif [[ -e $resources_dir/virtiofsd ]]; then
		fail 'Bundled virtiofsd present but not executable'
	else
		fail 'Bundled virtiofsd missing from resources/'
	fi

	# The bwrap fallback daemon (#776): staged beside app.asar when
	# patch_cowork_bwrap is active (it is, in every current build).
	# The launcher spawns it via a system node, so presence is the
	# contract — no exec bit required. Without it, an opt-in
	# COWORK_VM_BACKEND=bwrap launch fails at spawn with doctor
	# pointing at a reinstall.
	if [[ -f $resources_dir/cowork-vm-service.js ]]; then
		pass 'Bundled cowork-vm-service.js present (bwrap daemon)'
	else
		fail 'Bundled cowork-vm-service.js missing from resources/'
	fi

	# Extract app.asar for deeper inspection. This is not optional
	# cover: everything below — the package.json shape, productName,
	# and the StartupWMClass/desktopName agreement that closes #779 —
	# lives behind it, so a resolver that quietly gives up takes the
	# whole block with it and leaves the suite green on nothing read.
	#
	# The old fallback was `npx --yes @electron/asar`, which under
	# npm 9 resolves to a 4.x that refuses to start on Node 20 (#839);
	# the extract then failed and the skip branch reported [PASS].
	# Resolve a runnable asar or fail.
	#
	# @electron/asar@3 (not @4): these tests only read the shipped
	# archive, which every major does identically, and 3.4.1 declares
	# engines.node >=10.12.0, so it runs anywhere. That is load-bearing
	# for CI as much as for a laptop — test-artifacts.yml runs no
	# actions/setup-node and takes whatever `apt-get install nodejs` or
	# `dnf install nodejs` hands it, which is not guaranteed to clear
	# 4.x's >=22.12.0 floor. It also keeps a local run on the Node 20
	# host from #839 asserting instead of stopping at the resolver.
	local extract_dir
	extract_dir=$(mktemp -d)

	# Redirected to a file, not captured with $(...): _resolve_asar sets
	# $asar_exec as a global, and a command substitution would run it in
	# a subshell that throws that assignment away — leaving the extract
	# below to invoke the empty string. Same subshell-discards-mutation
	# class as the `run`-wrapped assertions in
	# docs/learnings/test-methodology-and-coverage.md.
	local asar_log="$extract_dir/asar-resolve.log"
	if _resolve_asar "$extract_dir" 3 > "$asar_log" 2>&1; then
		pass "$(tail -1 "$asar_log")"
	else
		fail "Could not resolve a runnable asar: $(cat "$asar_log")"
		rm -rf "$extract_dir"
		return 1
	fi

	# The extract's own exit code is the last thing between a corrupt
	# app.asar and a green suite, so treat a failure the same way as an
	# unresolvable asar: report it and stop, rather than letting the
	# assertions below read an empty tree.
	if ! "$asar_exec" extract "$resources_dir/app.asar" \
		"$extract_dir/app"; then
		fail "asar extract failed on $resources_dir/app.asar"
		rm -rf "$extract_dir"
		return 1
	fi

	# Upstream entry point (main has shipped as index.js and
	# index.pre.js across releases — assert the stable prefix,
	# not the exact filename)
	assert_contains "$extract_dir/app/package.json" \
		'"main": ".vite/build/' \
		'package.json main points into .vite/build/'

	# productName drives Electron's userData path (~/.config/Claude);
	# the build tripwires the same invariant at patch time
	# (app-asar.sh)
	assert_contains "$extract_dir/app/package.json" \
		'"productName": "Claude"' \
		'package.json productName is Claude'

	# StartupWMClass must equal the asar desktopName minus its
	# .desktop suffix — the field Chromium derives the runtime
	# window class from. A drift here re-opens #779 (duplicate /
	# generic taskbar icon on GNOME and KDE).
	if [[ -n $desktop_file ]]; then
		local desktop_name wm_class
		desktop_name=$(grep -oP '"desktopName": "\K[^"]+' \
			"$extract_dir/app/package.json")
		wm_class="${desktop_name%.desktop}"
		# Mirror _derive_wm_class's guard: the glob rejects both an
		# empty value and one without a trailing .desktop suffix.
		if [[ $desktop_name != *.desktop ]]; then
			fail "asar desktopName '$desktop_name' is missing or has no .desktop suffix"
		elif grep -qx "StartupWMClass=$wm_class" "$desktop_file"; then
			pass "StartupWMClass matches asar desktopName ($wm_class)"
		else
			fail "StartupWMClass in $desktop_file does not match asar desktopName-derived '$wm_class'"
		fi
	fi

	# Main process bundle exists
	local main_bundle
	main_bundle=$(find "$extract_dir/app/.vite/build" \
		-maxdepth 1 -name 'index*.js' -type f | head -1)
	if [[ -n $main_bundle ]]; then
		pass 'Main process bundle present in .vite/build/'
	else
		fail 'No index*.js in .vite/build/'
	fi

	rm -rf "$extract_dir"
}

# Assert the launcher's --version fast-path (#775): it must print
# "<package_name> <version>" and exit 0. The fast-path exits before
# any launch, log-redirect, or sandbox logic, so unlike the launch
# smoke test it needs no display, D-Bus, or privilege handling — run
# the command directly. Closes the "deb/rpm static-verified only" gap
# from the #775 review.
#
# Usage: run_version_flag_test <label> <expected_prefix> <cmd> [args...]
#   expected_prefix  usually "<package_name> <version>"; matched as a
#                    prefix so an rpm caller can pass the %{VERSION}
#                    part and tolerate the raw hyphenated tail the
#                    launcher bakes in (see scripts/packaging/rpm.sh).
run_version_flag_test() {
	local label="$1" expected="$2"
	shift 2
	# An empty metadata query (dpkg-deb -f / rpm -qp failure) would
	# leave "name " as the expected prefix and make the match vacuous.
	if [[ -z $expected || $expected == *' ' ]]; then
		fail "$label --version: expected prefix '$expected' has no" \
			'version component (metadata query returned empty?)'
		return
	fi
	local out rc
	out=$("$@" --version 2>&1)
	rc=$?
	if (( rc == 0 )) && [[ $out == "$expected"* ]]; then
		pass "$label --version prints '$out' (exit 0)"
	else
		fail "$label --version: rc=$rc output='$out'" \
			"(want prefix '$expected')"
	fi
}

# Headless launch smoke test. Boots the packaged app under Xvfb + dbus
# and waits for the launcher's 'Executing:' log line (written
# immediately before exec'ing the official ELF), then requires the
# process group to survive a grace window. The 2.x frame-fix readiness
# marker died with the wrapper (patch-zero rebase) — the official
# bundle prints no deterministic startup line, so "reached exec and
# didn't crash within the grace period" is the honest contract now.
# Catches launcher breakage and immediate-exit startup regressions
# (bad patch anchors that yield a SyntaxError exit the main process
# within a second or two). Ref: #670 (deb/rpm), #646 (AppImage
# readiness-poll pattern this generalizes).
#
# Scope: main-process startup, plus a mapped-window check (#616). Once
# the grace window is clear the harness asks the X server it started
# whether a *mapped* window carrying the artifact's own WM_CLASS
# exists, which catches a main process that survives with no UI at all
# (BrowserWindow constructor throw, loadURL rejection, renderer crash
# during startup). It does not prove the renderer painted anything
# real: verified against the pinned 2.2553.1 bundle, the main window is
# constructed with `show: i && !u` (`u` is hard-coded false upstream;
# `i` is true unless launched with --startup or as an OS login item)
# and `opacity: +!!earlyWindowShow`, so it maps at construction — the
# only `ready-to-show` handlers on it emit telemetry. That is what
# makes the probe independent of claude.ai being reachable, and it is
# also the limit: a network error behind a blank (or opacity-0) window
# still passes. GPU/renderer crashes
# (#583-class) after startup still leave the main process and its
# window alive — Xvfb has no GPU, so Electron falls back to SwiftShader
# and that path isn't exercised here either.
#
# Usage:
#   run_launch_smoke_test <label> <pkill_match> <run_as> <cmd> [args...]
#     label       human name for pass/fail messages
#     pkill_match  pattern for the pkill -f child sweep (may be empty)
#     run_as       unprivileged user to drop to, or '' to run as-is.
#                  Electron aborts as root without --no-sandbox, and the
#                  launcher only adds that on Wayland/deb, so a root
#                  container (rpm) must drop privileges to exercise the
#                  real setuid-sandbox path.
#     cmd [args]   the launch command
#
# Tool absence (Xvfb/dbus-run-session/setsid, or runuser when a run_as
# user is requested) is a skip, not a failure — matching
# validate_app_contents; a missing xdotool skips the window probe alone
# and leaves the rest of the launch test running. Loud failure on
# missing tools belongs at the workflow layer, and test-artifacts.yml
# verifies every one of these — xdotool included — before the suite
# runs, so none of these skips can fire in CI.

# Module-scope state so the caller's trap can reap an interrupted launch.
_smoke_launch_pid=''
_smoke_xvfb_pid=''
_smoke_cache_root=''
_smoke_tmp=''
_smoke_pkill_match=''

# Reap the harness's own X server. It is ours now rather than
# xvfb-run's, and it lives deliberately OUTSIDE the launch process
# group so the test shell can keep talking to it while the app is
# reaped — which means no group kill ever reaches it.
#
# TERM before KILL so the server unlinks /tmp/.X11-unix/X<N> and
# /tmp/.X<N>-lock on the way out; SIGKILL alone leaves both behind on
# every run. Clears the PID so a second cleanup pass can't signal a
# number bash has already reaped and the kernel may have recycled.
_smoke_reap_xvfb() {
	[[ -n $_smoke_xvfb_pid ]] || return 0
	kill -TERM "$_smoke_xvfb_pid" 2>/dev/null
	local i
	for ((i = 0; i < 10; i++)); do
		kill -0 "$_smoke_xvfb_pid" 2>/dev/null || break
		sleep 0.1
	done
	kill -KILL "$_smoke_xvfb_pid" 2>/dev/null
	wait "$_smoke_xvfb_pid" 2>/dev/null
	_smoke_xvfb_pid=''
}

# Release everything one launch allocated: the X server and the two
# throwaway trees. Every exit path of run_launch_smoke_test lands here
# — normal, early-return and trap — so the handles are cleared rather
# than just the resources freed: the trap handler is installed on EXIT
# *and* INT/TERM, so a Ctrl-C runs it twice, and an empty handle is
# what makes the second pass a no-op instead of a signal to a PID bash
# has already reaped and the kernel may have recycled.
_smoke_release() {
	_smoke_reap_xvfb
	[[ -n $_smoke_cache_root ]] && rm -rf "$_smoke_cache_root"
	[[ -n $_smoke_tmp ]] && rm -rf "$_smoke_tmp"
	_smoke_launch_pid=''
	_smoke_cache_root=''
	_smoke_tmp=''
}

_launch_smoke_cleanup() {
	if [[ -n $_smoke_launch_pid ]]; then
		# Negative PID targets the whole process group.
		kill -KILL -- "-$_smoke_launch_pid" 2>/dev/null
		[[ -n $_smoke_pkill_match ]] \
			&& pkill -KILL -f "$_smoke_pkill_match" 2>/dev/null
	fi
	_smoke_release
	_replaced_ui_cleanup
}

# Module-scope state so the caller's trap can reap the stand-in
# processes run_replaced_ui_cleanup_test leaves behind on interrupt.
_replaced_ui_pids=()
_replaced_ui_tmp=''

_replaced_ui_cleanup() {
	local pid
	for pid in "${_replaced_ui_pids[@]}"; do
		kill -KILL "$pid" 2>/dev/null
	done
	[[ -n $_replaced_ui_tmp ]] && rm -rf "$_replaced_ui_tmp"
}

# Start a long-lived stand-in for a running UI: a copy of bash at $1,
# blocked on a fifo, carrying the --class fingerprint the launcher keys
# on. Prints the stand-in's own PID (not the setsid/runuser wrapper's).
# $2 is the fifo, $3 the WM_CLASS, the rest the optional runuser prefix.
# Runs in the caller's $(...), so the caller records the PID for the
# trap — an append here would die with the subshell.
_replaced_ui_spawn() {
	local bin="$1" fifo="$2" wm_class="$3"
	shift 3
	cp /bin/bash "$bin" || return 1
	# shellcheck disable=SC2016  # inner shell expands $1
	"$@" setsid "$bin" -c 'read -r _ < "$1"' claude-desktop "$fifo" \
		"--class=$wm_class" 3>&- </dev/null >/dev/null 2>&1 &
	local deadline=$((SECONDS + 5)) pid=''
	while ((SECONDS < deadline)); do
		pid=$(pgrep -f -- "^$bin " | head -1)
		[[ -n $pid ]] && break
		sleep 0.2
	done
	[[ -n $pid ]] || return 1
	echo "$pid"
}

# Exercise cleanup_replaced_desktop_ui through the INSTALLED launcher.
# A fingerprinted stand-in whose executable has been unlinked — the
# kernel marks /proc/PID/exe " (deleted)", exactly what dpkg/rpm do to
# a running instance on upgrade — must be killed and logged; one whose
# executable is intact must survive untouched. The cleanup runs before
# the launcher's display check, so this needs no Xvfb: the launcher is
# expected to exit 1 on "no display" after the cleanup has run.
# AppImage has no leg here: the binary lives inside the FUSE mount,
# which stays valid after the .AppImage file is replaced, so the marker
# never appears and the cleanup is a no-op by construction.
#
# Usage: run_replaced_ui_cleanup_test LABEL RUN_AS LIB_DIR LAUNCHER...
#   RUN_AS   unprivileged user to run as (empty = current user)
#   LIB_DIR  the install's lib dir, holding launcher-common.sh
run_replaced_ui_cleanup_test() {
	local label="$1" run_as="$2" lib_dir="$3"
	shift 3

	local wm_class
	wm_class=$(grep -oP "^readonly WM_CLASS='\K[^']+" \
		"$lib_dir/launcher-common.sh")
	if [[ -z $wm_class ]]; then
		fail "$label: WM_CLASS not found in $lib_dir/launcher-common.sh"
		return
	fi

	local -a as=()
	if [[ -n $run_as ]]; then
		if ! command -v runuser &>/dev/null; then
			pass "Skipping replaced-UI cleanup test for $label (runuser missing)"
			return
		fi
		as=(runuser -u "$run_as" --)
	fi

	local tmp
	tmp=$(mktemp -d)
	_replaced_ui_tmp="$tmp"
	# The unprivileged user must traverse $tmp and write the redirected
	# cache the launcher logs into.
	[[ -n $run_as ]] && chmod 0777 "$tmp"
	mkfifo "$tmp/block"
	local launcher_log="$tmp/cache/claude-desktop-debian/launcher.log"

	# Launcher with no display: every cleanup runs, then check_display
	# exits 1. Nothing else about the exit status is asserted.
	# env(1) takes -u only ahead of the NAME=VALUE pairs.
	_run_launcher() {
		"${as[@]}" env -u DISPLAY -u WAYLAND_DISPLAY \
			"XDG_CACHE_HOME=$tmp/cache" "XDG_CONFIG_HOME=$tmp/config" \
			"$@" >/dev/null 2>&1 || true
	}

	# --- replaced: executable unlinked underneath the process ---
	local stale_pid
	stale_pid=$(_replaced_ui_spawn "$tmp/claude-desktop" "$tmp/block" \
		"$wm_class" "${as[@]}") || {
		fail "$label: could not start the replaced-UI stand-in"
		return
	}
	_replaced_ui_pids+=("$stale_pid")
	rm "$tmp/claude-desktop"
	if ! "${as[@]}" readlink "/proc/$stale_pid/exe" \
		| grep -q ' (deleted)$'; then
		fail "$label: stand-in's /proc/PID/exe lacks the (deleted) marker"
		return
	fi

	_run_launcher "$@"

	local deadline=$((SECONDS + 3))
	while kill -0 "$stale_pid" 2>/dev/null && ((SECONDS < deadline)); do
		sleep 0.2
	done
	if kill -0 "$stale_pid" 2>/dev/null; then
		fail "$label: replaced UI stand-in (PID $stale_pid) survived launch"
	else
		pass "$label: replaced UI stand-in killed on launch"
	fi
	if grep -qF 'Killed replaced Claude Desktop UI' "$launcher_log" \
		2>/dev/null; then
		pass "$label: launcher logged the replaced-UI kill"
	else
		fail "$label: no 'Killed replaced Claude Desktop UI' in launcher log"
	fi

	# --- intact: same fingerprint, executable still on disk ---
	local live_pid kills_before kills_after
	live_pid=$(_replaced_ui_spawn "$tmp/claude-desktop-live" "$tmp/block" \
		"$wm_class" "${as[@]}") || {
		fail "$label: could not start the intact-UI stand-in"
		return
	}
	_replaced_ui_pids+=("$live_pid")
	kills_before=$(grep -cF 'Killed replaced Claude Desktop UI' \
		"$launcher_log" 2>/dev/null || true)

	_run_launcher "$@"

	kills_after=$(grep -cF 'Killed replaced Claude Desktop UI' \
		"$launcher_log" 2>/dev/null || true)
	if kill -0 "$live_pid" 2>/dev/null; then
		pass "$label: intact UI stand-in survived launch"
	else
		fail "$label: intact UI stand-in (PID $live_pid) was killed"
	fi
	if [[ ${kills_before:-0} == "${kills_after:-0}" ]]; then
		pass "$label: no replaced-UI kill logged for an intact UI"
	else
		fail "$label: launcher logged a replaced-UI kill for an intact UI"
	fi

	kill "$live_pid" 2>/dev/null
	unset -f _run_launcher
}

# True when any passed log file carries the sandbox-namespace-denied
# signature: the CI container forbidding Chromium's user/PID namespace
# sandbox. Matches `Failed to move to new namespace`,
# `zygote_host_impl_linux`, or `Operation not permitted` co-occurring
# with `namespace`. Missing files are skipped silently.
_smoke_sandbox_denied() {
	local log
	for log in "$@"; do
		[[ -f $log ]] || continue
		grep -qE 'Failed to move to new namespace|zygote_host_impl_linux' \
			"$log" && return 0
		grep -q 'Operation not permitted' "$log" \
			&& grep -q 'namespace' "$log" && return 0
	done
	return 1
}

# The narrow sandbox escape hatch, worded once. Both the pre-marker
# branch and the window probe can land on it, and two copies of a
# paragraph this long drift.
_smoke_sandbox_skip() {
	pass "$1: SKIP — Chromium sandbox cannot initialize in this container (namespace creation denied by seccomp/userns policy); launch not exercised here. App boots where the sandbox is permitted (see deb/appimage jobs)."
}

# Everything the harness captured about a launch, dumped to stderr.
# Both failure paths need it: a window probe that fails because the app
# crashed *after* the grace window is unreadable without the launcher
# log that recorded the exit code.
_smoke_dump_logs() {
	local launcher_log="$1" launch_log="$2" xserver_log="$3"
	if [[ -f $launcher_log ]]; then
		echo '--- launcher.log (last 40 lines) ---' >&2
		tail -40 "$launcher_log" >&2
		echo '------------------------------------' >&2
	fi
	if [[ -s $launch_log ]]; then
		echo '--- launch stderr (last 20 lines) ---' >&2
		tail -20 "$launch_log" >&2
		echo '-------------------------------------' >&2
	fi
	if [[ -s $xserver_log ]]; then
		echo '--- Xvfb stderr (last 20 lines) ---' >&2
		tail -20 "$xserver_log" >&2
		echo '-----------------------------------' >&2
	fi
}

# True once the launch is over: the launcher recorded Electron's exit
# code, or the process group leader is gone. One definition, because
# the grace window and the window probe both poll on it and a verdict
# split between two copies of this test is a bug neither loop shows.
_smoke_app_died() {
	local launcher_log="$1"
	[[ -f $launcher_log ]] \
		&& grep -qF 'Electron exited with code:' "$launcher_log" \
		&& return 0
	kill -0 "$_smoke_launch_pid" 2>/dev/null || return 0
	return 1
}

# Window-existence probe (#616). Asks the X server the harness started
# whether the app mapped a window whose class is the one the artifact
# under test baked in.
#
# The class is read off the artifact, not guessed: it is derived at
# build time from the asar's package.json `desktopName`
# (scripts/patches/app-asar.sh) and lands in the launcher as
# `readonly WM_CLASS=` and in the .desktop file as `StartupWMClass=`.
# Here we take it from the `--class=` token on the launcher's own
# `Executing: ` line, which is the only copy reachable identically from
# all three formats (the deb/rpm launcher lives at a fixed path, the
# AppImage's is inside a squashfs the harness never mounts).
# validate_app_contents already pins WM_CLASS == StartupWMClass ==
# desktopName from the other direction, so the three agree or that
# assertion is red first.
#
# What is probed is the real X11 class, NOT the `--class=` cmdline
# fingerprint: launcher-common.sh:274-275 notes that Chromium ignores
# `--class` for the window class and derives it from `desktopName`, so
# a cmdline match would prove something else entirely.
#
# Verification level, honestly: this catches "main process alive, no
# UI". It does not catch a mapped-but-blank window — see the scope note
# above run_launch_smoke_test.
_smoke_window_probe() {
	local label="$1" display="$2" launcher_log="$3"
	local launch_log="$4" xserver_log="$5"
	local probe_timeout=20

	if ! command -v xdotool &>/dev/null; then
		pass "$label: window probe skipped (xdotool missing)"
		return
	fi

	# Anchored on the exec line, not on the first `--class=` anywhere in
	# the log: the launcher also logs an env block and (on the cleanup
	# path) the cmdlines of processes it matched, any of which could
	# grow a `--class=` and silently hand the probe the wrong class.
	local wm_class
	wm_class=$(grep -oP -- 'Executing: .*?--class=\K[^[:space:]]+' \
		"$launcher_log" | head -1)
	if [[ -z $wm_class ]]; then
		fail "$label: no --class= on the launcher's Executing: line" \
			'— cannot resolve the window class to probe for'
		return
	fi

	# `xdotool search` takes the pattern as its ONE positional argument;
	# --class is a flag saying "match it against the window class", not
	# an option that takes a value. The pattern is a POSIX extended
	# regex compiled with REG_ICASE, so anchor it and escape the dots a
	# reverse-DNS class carries (com.anthropic.Claude) — and the
	# case-insensitivity is load-bearing, because Chromium capitalizes
	# res_class ("xmessage" -> "Xmessage") while res_name stays lower.
	local pattern
	pattern=$(sed -E 's/[][^$.|?*+(){}\]/\\&/g' <<<"$wm_class")

	local deadline=$((SECONDS + probe_timeout)) found=0 died=0
	local xserver_dead=0
	while ((SECONDS < deadline)); do
		# --onlyvisible is the mapped check: an IsUnmapped window does
		# not count as a UI the user could see.
		if [[ -n $(DISPLAY="$display" xdotool search --onlyvisible \
			--class "^$pattern$" 2>/dev/null) ]]; then
			found=1
			break
		fi
		# Same liveness predicate the grace window polls on, so the two
		# loops can't disagree about whether the app is still up.
		if _smoke_app_died "$launcher_log"; then
			died=1
			break
		fi
		# Every xdotool call above is 2>/dev/null, so a dead X server
		# looks exactly like "no window found". Without this tick the
		# verdict would blame the artifact for the harness's own
		# display dying.
		if ! kill -0 "$_smoke_xvfb_pid" 2>/dev/null; then
			xserver_dead=1
			break
		fi
		sleep 0.5
	done

	if ((found == 1)); then
		pass "$label mapped an X11 window of class '$wm_class'"
		return
	fi

	local detail
	if ((died == 1)); then
		# Narrow escape hatch, checked HERE and nowhere else in this
		# function. The readiness marker is written before the launcher
		# execs Electron, so a container that denies Chromium's
		# namespace sandbox can abort the wrong side of the grace
		# window and land here rather than in the pre-marker branch.
		# But it belongs strictly inside the died branch: a main
		# process that is still alive cannot have been killed by
		# sandbox denial, and _smoke_sandbox_denied matches the bare
		# string zygote_host_impl_linux — which Chromium also logs as a
		# benign OOM-score warning on hosts without CAP_SYS_RESOURCE.
		# Checked any earlier, that warning would downgrade the
		# live-but-windowless failure this probe exists to catch.
		if _smoke_sandbox_denied "$launcher_log" "$launch_log"; then
			_smoke_sandbox_skip "$label"
			return
		fi
		# Outlived the grace window, then died before any window
		# appeared: a post-grace crash, not a mapping problem. This is
		# the #583-class case the probe is most likely to catch first,
		# so name the cause — blaming the window would send the reader
		# after the wrong bug.
		detail="$label died after the grace window without mapping a"
		detail+=" window of class '$wm_class'"
	elif ((xserver_dead == 1)); then
		# The harness's fault, not the artifact's. Say so, or the next
		# reader spends the afternoon looking for a window bug.
		detail="$label: the harness's Xvfb on $display died while the"
		detail+=' probe was running — launch not judged'
	else
		# Still alive with no window. Listing the same class WITHOUT
		# --onlyvisible separates "no such window at all" from "it
		# exists but never mapped" — but the list is mapped-or-not, so
		# don't label it as proof of an unmapped window: a window that
		# maps in the last tick before the deadline shows up here too.
		local matching
		matching=$(DISPLAY="$display" xdotool search --class \
			"^$pattern$" 2>/dev/null | tr '\n' ' ')
		# Same one-positional-pattern rule as above: `--any --name
		# --class` are three flags and '.' is the pattern ("a non-empty
		# name or class"). getwindowclassname does not exist in the
		# xdotool Ubuntu ships (1:3.20160805.1), so names are all we
		# can print here.
		echo "--- mapped windows on $display ---" >&2
		local wid
		while read -r wid; do
			[[ -n $wid ]] || continue
			printf '  %s %s\n' "$wid" \
				"$(DISPLAY="$display" xdotool getwindowname \
					"$wid" 2>/dev/null)" >&2
		done < <(DISPLAY="$display" xdotool search --onlyvisible \
			--any --name --class '.' 2>/dev/null)
		echo '----------------------------------' >&2
		detail="$label: no mapped window of class '$wm_class' on"
		detail+=" $display within ${probe_timeout}s"
		if [[ -n $matching ]]; then
			detail+=" (ids with that class, mapped or not:"
			detail+=" $matching)"
		fi
	fi
	_smoke_dump_logs "$launcher_log" "$launch_log" "$xserver_log"
	fail "$detail"
}

run_launch_smoke_test() {
	local label="$1" pkill_match="$2" run_as="$3"
	shift 3

	local skip="Skipping launch smoke test for $label"
	if ! { command -v Xvfb && command -v dbus-run-session \
		&& command -v setsid; } &>/dev/null; then
		pass "$skip (Xvfb/dbus-run-session/setsid missing)"
		return
	fi
	if [[ -n $run_as ]] && ! command -v runuser &>/dev/null; then
		pass "$skip (runuser missing)"
		return
	fi

	local cache_root smoke_tmp launch_log xserver_log launcher_log
	cache_root=$(mktemp -d)
	smoke_tmp=$(mktemp -d)
	launch_log="$smoke_tmp/launch.log"
	xserver_log="$smoke_tmp/xserver.log"
	launcher_log="$cache_root/claude-desktop-debian/launcher.log"
	_smoke_cache_root="$cache_root"
	_smoke_tmp="$smoke_tmp"
	_smoke_pkill_match="$pkill_match"

	# The X server is started here rather than via `xvfb-run -a` so the
	# test shell shares the display with the app and can probe it
	# (#616): xvfb-run exports DISPLAY only into the process it wraps,
	# so xdotool run from here would fail with "Can't open display"
	# rather than report "no window found".
	#
	# Display-number allocation was xvfb-run -a's job, so take it over
	# deliberately: -displayfd hands the choice back to the server,
	# which binds the first free number and writes it to the fd. That is
	# race-free against parallel jobs on one host, unlike any
	# scan-for-a-free-number-then-bind loop (including xvfb-run -a's,
	# which retries on collision). -nolisten tcp keeps the server local.
	#
	# -ac (access control off) is added on the privilege-drop path so
	# the rpm leg's throwaway user reaches the server deterministically
	# rather than depending on the host-based fallback an auth-less
	# server applies to local clients. Note what it is NOT: a security
	# boundary. Unlike xvfb-run we create no MIT-MAGIC-COOKIE, so this
	# display has no authorization records with or without -ac and any
	# local client can attach for the life of the test. That is accepted
	# for a throwaway display inside a CI job — said plainly here rather
	# than dressed up as hardening.
	local display_file="$smoke_tmp/display"
	: >"$display_file"
	local -a xvfb_args=(-displayfd 3 -screen 0 1280x720x24
		-nolisten tcp)
	[[ -n $run_as ]] && xvfb_args+=(-ac)
	Xvfb "${xvfb_args[@]}" 3>"$display_file" >"$xserver_log" 2>&1 &
	_smoke_xvfb_pid=$!

	local deadline display='' display_num='' xvfb_dead=0
	deadline=$((SECONDS + 10))
	while ((SECONDS < deadline)); do
		# `read` succeeds only once the terminating newline has landed,
		# so a half-written number can't be mistaken for a display.
		if IFS= read -r display_num <"$display_file" \
			&& [[ $display_num =~ ^[0-9]+$ ]]; then
			display=":$display_num"
			break
		fi
		if ! kill -0 "$_smoke_xvfb_pid" 2>/dev/null; then
			xvfb_dead=1
			break
		fi
		sleep 0.2
	done
	if [[ -z $display ]]; then
		# An unsupported flag or an unwritable /tmp/.X11-unix kills the
		# server in milliseconds; calling that a 10s timeout sends the
		# reader after a timing problem that isn't there.
		if ((xvfb_dead == 1)); then
			fail "$label: Xvfb exited before reporting a display"
		else
			fail "$label: Xvfb did not report a display within 10s"
		fi
		# Nothing was launched yet, so only the server has anything
		# to say — the empty paths are skipped by the dumper's tests.
		_smoke_dump_logs '' '' "$xserver_log"
		_smoke_release
		return
	fi

	# setsid puts dbus + launcher + electron in a fresh process group so
	# we can reap the whole tree via kill -- -PGID below (Xvfb itself
	# stays out of that group on purpose — see _launch_smoke_cleanup).
	# XDG_CACHE_HOME is redirected so the test owns the launcher log the
	# readiness marker is written to (the launcher execs electron with
	# stdout/stderr >> "$log_file").
	# XDG_CONFIG_HOME is redirected too, now that the verdict depends on
	# a window appearing: ~/.config/Claude is where hide-to-tray and
	# window state persist, so a maintainer running this against their
	# own profile could hard-fail a healthy artifact — and the launcher
	# honours XDG_CONFIG_HOME everywhere (launcher-common.sh:617, :685,
	# :814, :877), so this also keeps the test out of the real
	# ~/.config/autostart. Every leg now boots a first-run profile,
	# which is what CI's throwaway runner always gave us anyway.
	local config_root="$cache_root/config"
	mkdir -p "$config_root"

	local -a runner=(setsid)
	if [[ -n $run_as ]]; then
		# The unprivileged user must be able to write the redirected
		# cache and config (and read the world-readable install +
		# setuid sandbox).
		chmod 0777 "$cache_root" "$config_root"
		runner+=(runuser -u "$run_as" --)
	fi
	# WAYLAND_DISPLAY and CLAUDE_USE_WAYLAND are the two inputs that
	# still matter once WAYLAND_DISPLAY is unset — detect_display_backend
	# also reads XDG_CURRENT_DESKTOP and NIRI_SOCKET, but both sit behind
	# the is_wayland gate — and both are unset here: inherited from a
	# maintainer's Wayland session they
	# would put the app on the real compositor, its surface would never
	# appear on the Xvfb display, and the window probe would fail a
	# healthy artifact. (run_replaced_ui_cleanup_test unsets DISPLAY and
	# WAYLAND_DISPLAY for a related reason — it wants no UI at all.)
	runner+=(env -u WAYLAND_DISPLAY -u CLAUDE_USE_WAYLAND
		"XDG_CACHE_HOME=$cache_root" "XDG_CONFIG_HOME=$config_root"
		"DISPLAY=$display" dbus-run-session -- "$@")

	"${runner[@]}" >"$launch_log" 2>&1 &
	_smoke_launch_pid=$!

	# Poll for the launcher's pre-exec marker or early process death,
	# up to 30s; then hold a grace window in which an immediate app
	# crash (SyntaxError-class, bad ELF) still fails the test.
	local readiness_marker='Executing: '
	local readiness_timeout=30 grace=8 saw_marker=0
	deadline=$((SECONDS + readiness_timeout))
	while ((SECONDS < deadline)); do
		if [[ -f $launcher_log ]] \
			&& grep -qF "$readiness_marker" "$launcher_log"; then
			saw_marker=1
			break
		fi
		kill -0 "$_smoke_launch_pid" 2>/dev/null || break
		sleep 0.5
	done

	if ((saw_marker == 1)); then
		# Grace window: the launcher exec'd the app — now require it
		# to stay alive (the launcher logs the exit code if it dies).
		deadline=$((SECONDS + grace))
		while ((SECONDS < deadline)); do
			if _smoke_app_died "$launcher_log"; then
				saw_marker=0
				break
			fi
			sleep 0.5
		done
	fi

	if ((saw_marker == 1)); then
		pass "$label reached ready state under Xvfb"
		_smoke_window_probe "$label" "$display" "$launcher_log" \
			"$launch_log" "$xserver_log"
	else
		# Build the failure detail message, but defer the fail/skip
		# verdict until after we've dumped and scanned the logs below.
		local detail exit_code
		if kill -0 "$_smoke_launch_pid" 2>/dev/null; then
			detail="$label did not reach ready state within"
			detail+=" ${readiness_timeout}s"
		else
			wait "$_smoke_launch_pid" 2>/dev/null
			exit_code=$?
			detail="$label exited before reaching ready state"
			detail+=" (exit: $exit_code)"
		fi
		_smoke_dump_logs "$launcher_log" "$launch_log" "$xserver_log"
		# Narrow skip: the GHA container's default seccomp/userns policy
		# blocks Chromium's namespace sandbox, so the zygote aborts before
		# the readiness marker. That's an environment limit, not an app
		# defect (deb/appimage jobs prove the same code boots where the
		# sandbox is allowed). Treat ONLY this signature as a skip; every
		# other pre-marker exit stays a hard failure.
		if _smoke_sandbox_denied "$launcher_log" "$launch_log"; then
			_smoke_sandbox_skip "$label"
		else
			fail "$detail"
		fi
	fi

	kill -TERM -- "-$_smoke_launch_pid" 2>/dev/null || true
	sleep 1
	kill -KILL -- "-$_smoke_launch_pid" 2>/dev/null || true
	wait "$_smoke_launch_pid" 2>/dev/null || true
	# Sweep any electron child that escaped the group (e.g. zygote).
	# Under the rpm runuser path PAM re-setsid()s the child into its own
	# session/process group, so the negative-PID group kills above miss
	# it entirely — this pkill -f sweep is the ACTUAL reaper there, not a
	# belt-and-suspenders extra. Don't drop it.
	if [[ -n $pkill_match ]]; then
		pkill -KILL -f "$pkill_match" 2>/dev/null || true
	fi

	# The X server outlives the group kill by design (the probe above
	# needed it while the app was still up), so it is reaped explicitly
	# here — the same call the trap path makes.
	_smoke_release
}

print_summary() {
	echo
	echo '================================'
	printf 'Results: %d passed, %d failed\n' "$_pass_count" "$_fail_count"
	echo '================================'
	if [[ $_fail_count -gt 0 ]]; then
		exit 1
	fi
}
