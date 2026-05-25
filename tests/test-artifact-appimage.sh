#!/usr/bin/env bash
# Integration tests for AppImage artifacts

artifact_dir="${1:?Usage: $0 <artifact-dir>}"
artifact_dir="$(cd "$artifact_dir" && pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test-artifact-common.sh
source "$script_dir/test-artifact-common.sh"

component_id='io.github.aaddrick.claude-desktop-debian'

# Find the AppImage file (exclude .zsync)
appimage_file=$(find "$artifact_dir" -name '*.AppImage' \
	! -name '*.zsync' -type f | head -1)
if [[ -z $appimage_file ]]; then
	fail "No AppImage found in $artifact_dir"
	print_summary
fi
pass "Found AppImage: $(basename "$appimage_file")"

# --- AppImage is executable ---
chmod +x "$appimage_file"
assert_executable "$appimage_file"

# --- File type check ---
file_type=$(file -b "$appimage_file")
if [[ $file_type == *"ELF"* ]] || [[ $file_type == *"executable"* ]]; then
	pass "AppImage is an ELF executable"
else
	fail "AppImage file type unexpected: $file_type"
fi

# --- Extract AppImage ---
extract_dir=$(mktemp -d)
cd "$extract_dir" || exit 1
"$appimage_file" --appimage-extract >/dev/null 2>&1
appdir="$extract_dir/squashfs-root"

if [[ -d $appdir ]]; then
	pass "--appimage-extract succeeded"
else
	fail "--appimage-extract failed (no squashfs-root)"
	print_summary
fi

# --- AppDir structure ---
assert_file_exists "$appdir/AppRun"
assert_executable "$appdir/AppRun"

# Top-level desktop entry
if [[ -f "$appdir/${component_id}.desktop" ]]; then
	pass "Top-level .desktop file exists"
	assert_contains "$appdir/${component_id}.desktop" \
		'Type=Application' "Desktop entry Type correct"
	assert_contains "$appdir/${component_id}.desktop" \
		'Exec=AppRun' "Desktop entry Exec points to AppRun"
else
	fail "No top-level .desktop file"
fi

# Desktop entry in standard location
assert_file_exists \
	"$appdir/usr/share/applications/${component_id}.desktop"

# Top-level icon
if [[ -f "$appdir/${component_id}.png" ]]; then
	pass "Top-level icon present"
else
	fail "No top-level icon found"
fi

# .DirIcon
assert_file_exists "$appdir/.DirIcon"

# AppStream metadata
assert_file_exists \
	"$appdir/usr/share/metainfo/${component_id}.appdata.xml"

# --- Electron binary ---
electron_path="$appdir/usr/lib/node_modules/electron/dist/electron"
assert_file_exists "$electron_path"
assert_executable "$electron_path"

# --- Launcher library ---
assert_file_exists "$appdir/usr/lib/claude-desktop/launcher-common.sh"

# --- AppRun content ---
assert_contains "$appdir/AppRun" 'launcher-common.sh' \
	"AppRun sources launcher-common.sh"
assert_contains "$appdir/AppRun" 'run_doctor' \
	"AppRun references run_doctor"
assert_contains "$appdir/AppRun" 'build_electron_args' \
	"AppRun calls build_electron_args"

# --- App contents (asar) ---
resources_dir="$appdir/usr/lib/node_modules/electron/dist/resources"
validate_app_contents "$resources_dir" "${component_id}.desktop"

# --- Doctor smoke test ---
# Some --doctor checks fail in CI (no display, etc.); we only care that
# the script itself didn't crash via signal or exec failure (>=127).
doctor_exit=0
"$appimage_file" --doctor >/dev/null 2>&1 || doctor_exit=$?
if [[ $doctor_exit -lt 127 ]]; then
	pass "--doctor runs without crashing (exit: $doctor_exit)"
else
	fail "--doctor crashed (exit: $doctor_exit)"
fi

# --- Headless launch smoke test ---
# Catches startup-only regressions (asar/frame-fix-wrapper syntax errors)
# that pure structure checks miss.
#
# Scope: main-process startup failures only. GPU/renderer-process
# crashes (e.g. #583-class) leave the main process alive and pass
# this check — Xvfb has no GPU, so Electron falls back to SwiftShader
# and the GPU-crash path isn't exercised here.
if command -v xvfb-run &>/dev/null \
	&& command -v dbus-run-session &>/dev/null \
	&& command -v setsid &>/dev/null; then

	# XDG_CACHE_HOME redirect so the test owns the launcher log.
	cache_root=$(mktemp -d)
	export XDG_CACHE_HOME="$cache_root"
	launcher_log="$cache_root/claude-desktop-debian/launcher.log"

	# setsid puts xvfb-run + Xvfb + dbus + AppRun + electron in a fresh
	# process group; xvfb-run's EXIT trap alone leaves Xvfb behind on
	# TERM, so we need kill -- -PGID below.
	# AppRun redirects electron's stdout/stderr into launcher_log;
	# xvfb_log captures xvfb-run's own stderr.
	xvfb_log=$(mktemp)
	setsid xvfb-run -a -s '-screen 0 1280x720x24' \
		dbus-run-session -- "$appimage_file" \
		>"$xvfb_log" 2>&1 &
	launch_pid=$!

	# Safety net: covers Ctrl-C, CI timeout, or any earlier `exit` so we
	# never leak Xvfb/electron between launch and the explicit kill below.
	trap '
		kill -KILL -- "-$launch_pid" 2>/dev/null
		pkill -KILL -f "$appimage_file" 2>/dev/null
		rm -rf "$cache_root" "$xvfb_log"
	' EXIT INT TERM

	# Wait up to 30s for the frame-fix readiness marker, or early
	# process death. The marker is the last log line emitted by
	# scripts/frame-fix-wrapper.js after all patches are installed,
	# so reaching it means main-process startup finished without
	# crashing. Replaces a flat 10s sleep that was both slow on
	# healthy startups and a flake risk on noisy runners.
	readiness_marker='[Frame Fix] Patches built successfully'
	readiness_timeout=30
	deadline=$((SECONDS + readiness_timeout))
	saw_marker=0
	while ((SECONDS < deadline)); do
		if [[ -f $launcher_log ]] \
			&& grep -qF "$readiness_marker" \
				"$launcher_log"; then
			saw_marker=1
			break
		fi
		if ! kill -0 "$launch_pid" 2>/dev/null; then
			break
		fi
		sleep 0.5
	done

	if ((saw_marker == 1)); then
		pass "AppImage reached ready state under Xvfb"
	else
		if kill -0 "$launch_pid" 2>/dev/null; then
			fail "AppImage did not reach ready state within ${readiness_timeout}s"
		else
			wait "$launch_pid" 2>/dev/null
			exit_code=$?
			fail "AppImage exited before reaching ready state (exit: $exit_code)"
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
	fi

	# Negative PID targets the process group.
	kill -TERM -- "-$launch_pid" 2>/dev/null || true
	sleep 1
	kill -KILL -- "-$launch_pid" 2>/dev/null || true
	wait "$launch_pid" 2>/dev/null || true
	# Sweep any electron child that escaped the group (e.g. zygote).
	pkill -KILL -f "$appimage_file" 2>/dev/null || true

	rm -rf "$cache_root" "$xvfb_log"
	unset XDG_CACHE_HOME
else
	# Match the codebase convention (test-artifact-common.sh
	# validate_app_contents): tool absence is a skip, not a failure.
	# Loud failure on missing tools belongs at the workflow layer.
	pass "Skipping launch smoke test (xvfb-run/dbus-run-session/setsid missing)"
fi

# --- Cleanup ---
rm -rf "$extract_dir"

print_summary
