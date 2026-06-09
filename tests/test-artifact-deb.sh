#!/usr/bin/env bash
# Integration tests for .deb package artifacts

artifact_dir="${1:?Usage: $0 <artifact-dir>}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test-artifact-common.sh
source "$script_dir/test-artifact-common.sh"

# Reap an interrupted launch smoke test (see test-artifact-common.sh).
trap _launch_smoke_cleanup EXIT INT TERM

# Find the .deb file
deb_file=$(find "$artifact_dir" -name '*.deb' -type f | head -1)
if [[ -z $deb_file ]]; then
	fail "No .deb file found in $artifact_dir"
	print_summary
fi
pass "Found deb: $(basename "$deb_file")"

# --- Package metadata ---
pkg_info=$(dpkg-deb -I "$deb_file")

if [[ $pkg_info == *'Package: claude-desktop'* ]]; then
	pass "Package name is claude-desktop"
else
	fail "Package name is not claude-desktop"
fi

# Architecture must match the target we built for. TARGET_ARCH is set by
# the CI workflow's per-arch matrix; fall back to the host's dpkg
# architecture for standalone/local runs (each CI arch runs on a native
# runner, so the host arch matches the package arch there too).
expected_arch="${TARGET_ARCH:-$(dpkg --print-architecture 2>/dev/null)}"
if [[ -n $expected_arch ]] \
	&& [[ $pkg_info == *"Architecture: $expected_arch"* ]]; then
	pass "Architecture is $expected_arch"
else
	fail "Architecture is not ${expected_arch:-<undetermined>}"
fi

if [[ $pkg_info == *'Version:'* ]]; then
	pass "Version field present"
else
	fail "Version field missing"
fi

# --- Install the package ---
# Use --force-depends since we only care about file placement
if sudo dpkg -i --force-depends "$deb_file"; then
	pass "dpkg -i succeeded"
else
	fail "dpkg -i failed"
fi

# --- File existence checks ---
assert_executable '/usr/bin/claude-desktop'
assert_file_exists '/usr/share/applications/claude-desktop.desktop'
assert_file_exists \
	'/usr/share/metainfo/io.github.aaddrick.claude-desktop-debian.metainfo.xml'
assert_dir_exists '/usr/lib/claude-desktop'
assert_file_exists '/usr/lib/claude-desktop/launcher-common.sh'

# Electron binary
electron_path='/usr/lib/claude-desktop/node_modules/electron/dist/electron'
assert_file_exists "$electron_path"
assert_executable "$electron_path"

# chrome-sandbox
assert_file_exists \
	'/usr/lib/claude-desktop/node_modules/electron/dist/chrome-sandbox'

# The build's permission normalization clears the setuid bit; postinst
# must re-assert 4755 or the Electron sandbox breaks silently (#695).
assert_setuid \
	'/usr/lib/claude-desktop/node_modules/electron/dist/chrome-sandbox'

# --- Desktop entry validation ---
desktop_file='/usr/share/applications/claude-desktop.desktop'
assert_contains "$desktop_file" 'Exec=/usr/bin/claude-desktop' \
	"Desktop entry Exec field correct"
assert_contains "$desktop_file" 'Type=Application' \
	"Desktop entry Type field correct"
assert_contains "$desktop_file" 'Icon=claude-desktop' \
	"Desktop entry Icon field correct"

# Validate desktop file syntax if tool available
if command -v desktop-file-validate &>/dev/null; then
	assert_command_succeeds "desktop-file-validate passes" \
		desktop-file-validate "$desktop_file"
fi

# --- Icons ---
icon_dir='/usr/share/icons/hicolor'
icon_found=false
for size in 16 24 32 48 64 256; do
	if [[ -f "$icon_dir/${size}x${size}/apps/claude-desktop.png" ]]; then
		icon_found=true
	fi
done
if [[ $icon_found == true ]]; then
	pass "At least one icon installed in hicolor"
else
	fail "No icons found in hicolor"
fi

# --- Launcher script content ---
assert_contains '/usr/bin/claude-desktop' 'launcher-common.sh' \
	"Launcher sources launcher-common.sh"
assert_contains '/usr/bin/claude-desktop' 'run_doctor' \
	"Launcher references run_doctor"
assert_contains '/usr/bin/claude-desktop' 'build_electron_args' \
	"Launcher calls build_electron_args"

# --- App contents (asar) ---
resources_dir='/usr/lib/claude-desktop/node_modules/electron/dist/resources'
validate_app_contents "$resources_dir"

# app.asar.unpacked must be world-traversable and root-owned, or
# Cowork's auto-launch fs.existsSync() guard silently fails (#695).
unpacked_stat=$(stat -c '%a %U:%G' "$resources_dir/app.asar.unpacked")
if [[ $unpacked_stat == '755 root:root' ]]; then
	pass 'app.asar.unpacked is 755 root:root'
else
	fail "app.asar.unpacked is $unpacked_stat (want 755 root:root)"
fi

# --- Doctor smoke test ---
# --doctor checks system state; some checks will fail in CI (no display,
# etc.) but the script itself should not crash with signal or 127.
doctor_exit=0
/usr/bin/claude-desktop --doctor >/dev/null 2>&1 || doctor_exit=$?
if [[ $doctor_exit -lt 127 ]]; then
	pass "--doctor runs without crashing (exit: $doctor_exit)"
else
	fail "--doctor crashed (exit: $doctor_exit)"
fi

# --- Headless launch smoke test ---
# ubuntu-latest runs as a non-root user, so no privilege drop needed.
run_launch_smoke_test 'deb package' '/usr/lib/claude-desktop' '' \
	/usr/bin/claude-desktop

print_summary
