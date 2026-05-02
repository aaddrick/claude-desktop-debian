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

# --- Cleanup ---
rm -rf "$extract_dir"

print_summary
