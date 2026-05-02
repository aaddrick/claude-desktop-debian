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

print_summary() {
	echo
	echo '================================'
	printf 'Results: %d passed, %d failed\n' "$_pass_count" "$_fail_count"
	echo '================================'
	if [[ $_fail_count -gt 0 ]]; then
		exit 1
	fi
}
