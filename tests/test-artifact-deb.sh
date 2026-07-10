#!/usr/bin/env bash
# Integration tests for .deb package artifacts

artifact_dir="${1:?Usage: $0 <artifact-dir>}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test-artifact-common.sh
source "$script_dir/test-artifact-common.sh"

# Reap an interrupted launch smoke test (see test-artifact-common.sh).
trap _launch_smoke_cleanup EXIT INT TERM

# Find the main .deb file. Match the package name explicitly: the amd64
# leg also emits the transitional claude-desktop_*_all.deb (tested at
# the bottom), so a bare '*.deb' glob would be nondeterministic here.
deb_file=$(find "$artifact_dir" -name 'claude-desktop-unofficial_*.deb' \
	-type f | head -1)
if [[ -z $deb_file ]]; then
	fail "No claude-desktop-unofficial .deb file found in $artifact_dir"
	print_summary
fi
pass "Found deb: $(basename "$deb_file")"

# --- Package metadata ---
pkg_info=$(dpkg-deb -I "$deb_file")

if [[ $pkg_info == *'Package: claude-desktop-unofficial'* ]]; then
	pass "Package name is claude-desktop-unofficial"
else
	fail "Package name is not claude-desktop-unofficial"
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

# Phase 3 rename: the package must conflict with and replace the
# pre-rename package name below upstream's first Linux release, so an
# upgrade from our old claude-desktop cleanly hands over its files.
if [[ $pkg_info == *'Conflicts: claude-desktop (<< 1.16000)'* ]]; then
	pass 'Control has Conflicts: claude-desktop (<< 1.16000)'
else
	fail 'Control lacks Conflicts: claude-desktop (<< 1.16000)'
fi

if [[ $pkg_info == *'Replaces: claude-desktop (<< 1.16000)'* ]]; then
	pass 'Control has Replaces: claude-desktop (<< 1.16000)'
else
	fail 'Control lacks Replaces: claude-desktop (<< 1.16000)'
fi

# --- Install the package ---
# Use --force-depends since we only care about file placement
if sudo dpkg -i --force-depends "$deb_file"; then
	pass "dpkg -i succeeded"
else
	fail "dpkg -i failed"
fi

# --- File existence checks ---
assert_executable '/usr/bin/claude-desktop-unofficial'
assert_file_exists \
	'/usr/share/applications/claude-desktop-unofficial.desktop'
assert_file_exists \
	'/usr/share/metainfo/io.github.aaddrick.claude-desktop-unofficial.metainfo.xml'

# Regression guard (#769): the metainfo basename must follow the
# package rename so it can no longer collide with a pre-rename
# claude-desktop build of this project (which still owns the
# ...debian.metainfo.xml path). Anthropic's official package ships
# no metainfo, so it is never a collision party.
if dpkg-deb -c "$deb_file" \
		| grep -q 'io\.github\.aaddrick\.claude-desktop-debian\.metainfo\.xml'; then
	fail 'deb still ships pre-rename metainfo path (#769)'
else
	pass 'deb no longer ships pre-rename metainfo path (#769)'
fi

assert_dir_exists '/usr/lib/claude-desktop-unofficial'
assert_file_exists '/usr/lib/claude-desktop-unofficial/launcher-common.sh'

# Electron binary. The official tree is bare co-located: the ELF, its
# chrome-sandbox, and resources/ live directly under
# /usr/lib/claude-desktop-unofficial — there is no
# node_modules/electron/dist wrapper (rebase onto the official .deb; see
# deb.sh `cp -a "$app_staging_dir/."`). The inner ELF keeps the upstream
# basename claude-desktop; only the parent directory is renamed.
electron_path='/usr/lib/claude-desktop-unofficial/claude-desktop'
assert_file_exists "$electron_path"
assert_executable "$electron_path"

# chrome-sandbox
assert_file_exists \
	'/usr/lib/claude-desktop-unofficial/chrome-sandbox'

# The build's permission normalization clears the setuid bit; postinst
# must re-assert 4755 or the Electron sandbox breaks silently (#695).
assert_setuid \
	'/usr/lib/claude-desktop-unofficial/chrome-sandbox'

# --- Desktop entry validation ---
desktop_file='/usr/share/applications/claude-desktop-unofficial.desktop'
assert_contains "$desktop_file" \
	'Exec=/usr/bin/claude-desktop-unofficial %u' \
	"Desktop entry Exec field correct"
assert_contains "$desktop_file" 'Type=Application' \
	"Desktop entry Type field correct"
assert_contains "$desktop_file" 'Icon=claude-desktop-unofficial' \
	"Desktop entry Icon field correct"

# Validate desktop file syntax if tool available
if command -v desktop-file-validate &>/dev/null; then
	assert_command_succeeds "desktop-file-validate passes" \
		desktop-file-validate "$desktop_file"
fi

# --- Icons ---
icon_dir='/usr/share/icons/hicolor'
icon_name='claude-desktop-unofficial.png'
icon_found=false
for size in 16 24 32 48 64 256; do
	if [[ -f "$icon_dir/${size}x${size}/apps/$icon_name" ]]; then
		icon_found=true
	fi
done
if [[ $icon_found == true ]]; then
	pass "At least one icon installed in hicolor"
else
	fail "No icons found in hicolor"
fi

# --- Launcher script content ---
assert_contains '/usr/bin/claude-desktop-unofficial' 'launcher-common.sh' \
	"Launcher sources launcher-common.sh"
assert_contains '/usr/bin/claude-desktop-unofficial' 'run_doctor' \
	"Launcher references run_doctor"
assert_contains '/usr/bin/claude-desktop-unofficial' 'build_electron_args' \
	"Launcher calls build_electron_args"

# --- App contents (asar) ---
resources_dir='/usr/lib/claude-desktop-unofficial/resources'
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
/usr/bin/claude-desktop-unofficial --doctor >/dev/null 2>&1 \
	|| doctor_exit=$?
if [[ $doctor_exit -lt 127 ]]; then
	pass "--doctor runs without crashing (exit: $doctor_exit)"
else
	fail "--doctor crashed (exit: $doctor_exit)"
fi

# --- Launcher --version fast-path (#775) ---
# The control Version is the exact string deb.sh baked into the
# launcher's echo, so this asserts the full line.
run_version_flag_test 'deb launcher' \
	"claude-desktop-unofficial $(dpkg-deb -f "$deb_file" Version)" \
	/usr/bin/claude-desktop-unofficial

# --- Headless launch smoke test ---
# ubuntu-latest runs as a non-root user, so no privilege drop needed.
run_launch_smoke_test 'deb package' '/usr/lib/claude-desktop-unofficial' \
	'' /usr/bin/claude-desktop-unofficial

# --- Transitional dummy package (amd64 leg only) ---
# The amd64 build also emits claude-desktop_1.16000.0-1_all.deb: an
# empty oldlibs package whose Depends pulls claude-desktop-unofficial
# in for users upgrading from the pre-rename package name. Skip when
# absent (arm64 leg, or a local single-artifact run).
transitional_deb=$(find "$artifact_dir" -name 'claude-desktop_*_all.deb' \
	-type f | head -1)
if [[ -z $transitional_deb ]]; then
	pass 'Transitional claude-desktop deb absent; skipping its checks'
else
	pass "Found transitional deb: $(basename "$transitional_deb")"
	trans_info=$(dpkg-deb -I "$transitional_deb")

	# Anchor on end-of-line: a plain substring match would also accept
	# 'Package: claude-desktop-unofficial'.
	if grep -qE '^ *Package: claude-desktop$' <<<"$trans_info"; then
		pass 'Transitional package name is exactly claude-desktop'
	else
		fail 'Transitional package name is not claude-desktop'
	fi

	if [[ $trans_info == *'Version: 1.16000.0-1'* ]]; then
		pass 'Transitional version is 1.16000.0-1'
	else
		fail 'Transitional version is not 1.16000.0-1'
	fi

	if [[ $trans_info == *'Architecture: all'* ]]; then
		pass 'Transitional architecture is all'
	else
		fail 'Transitional architecture is not all'
	fi

	if grep -qE '^ *Depends:.*claude-desktop-unofficial' \
		<<<"$trans_info"; then
		pass 'Transitional Depends includes claude-desktop-unofficial'
	else
		fail 'Transitional Depends lacks claude-desktop-unofficial'
	fi

	if dpkg-deb -c "$transitional_deb" | grep -q '\./usr/lib'; then
		fail 'Transitional deb ships files under /usr/lib'
	else
		pass 'Transitional deb ships no files under /usr/lib'
	fi
fi

print_summary
