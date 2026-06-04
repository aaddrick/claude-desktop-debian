#!/usr/bin/env bash
# Shared helpers for artifact validation tests

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
	if [[ -u $1 ]]; then
		pass "Setuid bit set: $1"
	else
		fail "Setuid bit not set: $1"
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
# $1 = path to the resources/ dir containing app.asar
# $2 = expected desktopName in app/package.json
validate_app_contents() {
	local resources_dir="$1"
	local expected_desktop_name="${2:-claude-desktop.desktop}"

	assert_file_exists "$resources_dir/app.asar"
	assert_dir_exists "$resources_dir/app.asar.unpacked"

	# Check unpacked contents (always available, no asar tool needed)
	assert_file_exists \
		"$resources_dir/app.asar.unpacked/node_modules/@ant/claude-native/index.js"
	assert_file_exists \
		"$resources_dir/app.asar.unpacked/cowork-vm-service.js"

	# Extract app.asar for deeper inspection if tools available
	local extract_dir
	extract_dir=$(mktemp -d)

	local extracted=false
	if command -v asar &>/dev/null; then
		asar extract "$resources_dir/app.asar" "$extract_dir/app" \
			&& extracted=true
	elif command -v npx &>/dev/null; then
		npx --yes @electron/asar extract \
			"$resources_dir/app.asar" "$extract_dir/app" 2>/dev/null \
			&& extracted=true
	fi

	if [[ $extracted == true ]]; then
		# frame-fix files present
		assert_file_exists "$extract_dir/app/frame-fix-wrapper.js"
		assert_file_exists "$extract_dir/app/frame-fix-entry.js"

		# package.json main points to frame-fix-entry.js
		assert_contains "$extract_dir/app/package.json" \
			'frame-fix-entry.js' \
			"package.json main field references frame-fix-entry.js"

		# package.json desktopName matches the installed desktop file
		assert_contains "$extract_dir/app/package.json" \
			"\"desktopName\": \"$expected_desktop_name\"" \
			"package.json desktopName matches $expected_desktop_name"

		# .vite/build/index.js exists (main process code)
		assert_file_exists "$extract_dir/app/.vite/build/index.js"

		# claude-native stub exists inside asar
		assert_file_exists \
			"$extract_dir/app/node_modules/@ant/claude-native/index.js"

		# cowork-vm-service.js exists inside asar
		assert_file_exists "$extract_dir/app/cowork-vm-service.js"

		# frame-fix-entry.js loads the wrapper
		assert_contains "$extract_dir/app/frame-fix-entry.js" \
			'frame-fix-wrapper' \
			"frame-fix-entry.js loads wrapper"

		# Tray icons present in resources
		local tray_count
		tray_count=$(find "$extract_dir/app/resources/" \
			-name 'Tray*' 2>/dev/null | wc -l)
		if [[ $tray_count -gt 0 ]]; then
			pass "Tray icons present ($tray_count files)"
		else
			fail "No tray icons found in app resources"
		fi
	else
		pass "Skipping asar extraction (tool not available)"
	fi

	rm -rf "$extract_dir"
}

# Headless launch smoke test. Boots the packaged app under Xvfb + dbus
# and waits for the frame-fix readiness marker
# ('[Frame Fix] Patches built successfully'), which scripts/frame-fix-
# wrapper.js emits on the FIRST require('electron') — i.e. before
# app.whenReady(), not after full startup. Reaching it proves the asar
# loaded and the wrapper's electron interception ran without a
# SyntaxError (the #666 class) — note a hang after this point would
# still pass. Catches startup-only regressions (asar/wrapper syntax
# errors, bad patch anchors that yield a SyntaxError) that pure
# structure checks miss. Ref: #670 (deb/rpm),
# #646 (AppImage readiness-poll pattern this generalizes).
#
# Scope: main-process startup only. GPU/renderer crashes (#583-class)
# leave the main process alive and pass — Xvfb has no GPU, so Electron
# falls back to SwiftShader and that path isn't exercised here.
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
# Tool absence (xvfb-run/dbus-run-session/setsid, or runuser when a
# run_as user is requested) is a skip, not a failure — matching
# validate_app_contents. Loud failure on missing tools belongs at the
# workflow layer.

# Module-scope state so the caller's trap can reap an interrupted launch.
_smoke_launch_pid=''
_smoke_cache_root=''
_smoke_xvfb_log=''
_smoke_pkill_match=''

_launch_smoke_cleanup() {
	if [[ -n $_smoke_launch_pid ]]; then
		# Negative PID targets the whole process group.
		kill -KILL -- "-$_smoke_launch_pid" 2>/dev/null
		[[ -n $_smoke_pkill_match ]] \
			&& pkill -KILL -f "$_smoke_pkill_match" 2>/dev/null
	fi
	[[ -n $_smoke_cache_root ]] && rm -rf "$_smoke_cache_root"
	[[ -n $_smoke_xvfb_log ]] && rm -rf "$_smoke_xvfb_log"
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

run_launch_smoke_test() {
	local label="$1" pkill_match="$2" run_as="$3"
	shift 3

	local skip="Skipping launch smoke test for $label"
	if ! { command -v xvfb-run && command -v dbus-run-session \
		&& command -v setsid; } &>/dev/null; then
		pass "$skip (xvfb-run/dbus-run-session/setsid missing)"
		return
	fi
	if [[ -n $run_as ]] && ! command -v runuser &>/dev/null; then
		pass "$skip (runuser missing)"
		return
	fi

	local cache_root xvfb_log launcher_log
	cache_root=$(mktemp -d)
	xvfb_log=$(mktemp)
	launcher_log="$cache_root/claude-desktop-debian/launcher.log"
	_smoke_cache_root="$cache_root"
	_smoke_xvfb_log="$xvfb_log"
	_smoke_pkill_match="$pkill_match"

	# setsid puts xvfb-run + Xvfb + dbus + launcher + electron in a fresh
	# process group; xvfb-run's own EXIT trap leaves Xvfb behind on TERM,
	# so we reap via kill -- -PGID below. XDG_CACHE_HOME is redirected so
	# the test owns the launcher log the readiness marker is written to
	# (the launcher execs electron with stdout/stderr >> "$log_file").
	local -a runner=(setsid)
	if [[ -n $run_as ]]; then
		# The unprivileged user must be able to write the redirected
		# cache (and read the world-readable install + setuid sandbox).
		chmod 0777 "$cache_root"
		runner+=(runuser -u "$run_as" --)
	fi
	runner+=(env "XDG_CACHE_HOME=$cache_root"
		xvfb-run -a -s '-screen 0 1280x720x24'
		dbus-run-session -- "$@")

	"${runner[@]}" >"$xvfb_log" 2>&1 &
	_smoke_launch_pid=$!

	# Poll for the readiness marker or early process death, up to 30s.
	# Replaces a flat sleep: faster on healthy startups, less flaky on
	# noisy runners.
	local readiness_marker='[Frame Fix] Patches built successfully'
	local readiness_timeout=30 deadline saw_marker=0
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
		pass "$label reached ready state under Xvfb"
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
		if [[ -f $launcher_log ]]; then
			echo '--- launcher.log (last 40 lines) ---' >&2
			tail -40 "$launcher_log" >&2
			echo '------------------------------------' >&2
		fi
		if [[ -s $xvfb_log ]]; then
			echo '--- xvfb-run stderr (last 20 lines) ---' >&2
			tail -20 "$xvfb_log" >&2
			echo '---------------------------------------' >&2
		fi
		# Narrow skip: the GHA container's default seccomp/userns policy
		# blocks Chromium's namespace sandbox, so the zygote aborts before
		# the readiness marker. That's an environment limit, not an app
		# defect (deb/appimage jobs prove the same code boots where the
		# sandbox is allowed). Treat ONLY this signature as a skip; every
		# other pre-marker exit stays a hard failure.
		if _smoke_sandbox_denied "$launcher_log" "$xvfb_log"; then
			pass "$label: SKIP — Chromium sandbox cannot initialize in this container (namespace creation denied by seccomp/userns policy); launch not exercised here. App boots where the sandbox is permitted (see deb/appimage jobs)."
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

	rm -rf "$cache_root" "$xvfb_log"
	_smoke_launch_pid=''
	_smoke_cache_root=''
	_smoke_xvfb_log=''
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
