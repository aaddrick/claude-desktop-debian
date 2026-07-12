#!/usr/bin/env bash
# Integration tests for .rpm package artifacts

artifact_dir="${1:?Usage: $0 <artifact-dir>}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/test-artifact-common.sh
source "$script_dir/test-artifact-common.sh"

# Reap an interrupted launch smoke test, then remove the throwaway
# unprivileged user the launch drops to (see below / test-artifact-
# common.sh).
_rpm_cleanup() {
	_launch_smoke_cleanup
	[[ -n ${smoke_user:-} ]] \
		&& userdel -r "$smoke_user" 2>/dev/null
}
trap _rpm_cleanup EXIT INT TERM

# Find the .rpm file
rpm_file=$(find "$artifact_dir" -name '*.rpm' -type f | head -1)
if [[ -z $rpm_file ]]; then
	fail "No .rpm file found in $artifact_dir"
	print_summary
fi
pass "Found rpm: $(basename "$rpm_file")"

# --- RPM metadata ---
rpm_info=$(rpm -qip "$rpm_file" 2>/dev/null)

if [[ $rpm_info =~ Name.*claude-desktop-unofficial ]]; then
	pass "Package name is claude-desktop-unofficial"
else
	fail "Package name is not claude-desktop-unofficial"
fi

# Phase 3 rename: the rpm must obsolete the pre-rename package name
# (clean upgrade path for existing installs) and provide it for
# anything that depends on claude-desktop.
rpm_obsoletes=$(rpm -qp --obsoletes "$rpm_file" 2>/dev/null)
if [[ $rpm_obsoletes == *'claude-desktop < 1.16000'* ]]; then
	pass 'Obsoletes: claude-desktop < 1.16000'
else
	fail 'Missing Obsoletes: claude-desktop < 1.16000'
fi

# 'claude-desktop =' cannot false-match the self-provide: in
# 'claude-desktop-unofficial = ...' the name is followed by
# '-unofficial', not ' ='.
rpm_provides=$(rpm -qp --provides "$rpm_file" 2>/dev/null)
if [[ $rpm_provides == *'claude-desktop ='* ]]; then
	pass 'Provides: claude-desktop = <version>'
else
	fail 'Missing Provides: claude-desktop = <version>'
fi

# --- Install ---
if rpm -ivh --nodeps "$rpm_file"; then
	pass "rpm -ivh succeeded"
else
	fail "rpm -ivh failed"
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
if rpm -qlp "$rpm_file" \
		| grep -q 'io\.github\.aaddrick\.claude-desktop-debian\.metainfo\.xml'; then
	fail 'rpm still ships pre-rename metainfo path (#769)'
else
	pass 'rpm no longer ships pre-rename metainfo path (#769)'
fi

assert_dir_exists '/usr/lib/claude-desktop-unofficial'
assert_file_exists '/usr/lib/claude-desktop-unofficial/launcher-common.sh'

# Electron binary. Official tree is bare co-located under
# /usr/lib/claude-desktop-unofficial (ELF + chrome-sandbox +
# resources/), with no node_modules/electron/dist wrapper — see rpm.sh
# `cp -a`. The inner ELF keeps the upstream basename claude-desktop;
# only the parent directory is renamed.
electron_path='/usr/lib/claude-desktop-unofficial/claude-desktop'
assert_file_exists "$electron_path"
assert_executable "$electron_path"

# chrome-sandbox: setuid bit must be set by the rpm spec's %files
# %attr(4755, ...) entry, not by a %post chmod (#539). The check
# guards against any regression that strips the suid bit — including
# (but not limited to) reverting to a %post chmod, which silently
# no-ops if the scriptlet is skipped (--noscripts, layered images).
chrome_sandbox='/usr/lib/claude-desktop-unofficial/chrome-sandbox'
assert_file_exists "$chrome_sandbox"
assert_setuid "$chrome_sandbox"

# --- Desktop entry validation ---
desktop_file='/usr/share/applications/claude-desktop-unofficial.desktop'
assert_contains "$desktop_file" \
	'Exec=/usr/bin/claude-desktop-unofficial %u' \
	"Desktop entry Exec correct"
assert_contains "$desktop_file" 'Type=Application' \
	"Desktop entry Type correct"
assert_contains "$desktop_file" 'Icon=claude-desktop-unofficial' \
	"Desktop entry Icon correct"

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

# --- CW-1: Cowork firmware compat shim in the scriptlets ---
# The runtime effect needs an edk2 layout the container doesn't have;
# assert the scriptlet content instead.
rpm_scripts=$(rpm -q --scripts claude-desktop-unofficial 2>/dev/null)
if [[ $rpm_scripts == *'Cowork firmware compat symlink'* ]]; then
	pass "%post carries the CW-1 firmware compat shim"
else
	fail "%post is missing the CW-1 firmware compat shim"
fi

# --- App contents (asar) ---
resources_dir='/usr/lib/claude-desktop-unofficial/resources'
validate_app_contents "$resources_dir" "$desktop_file"

# app.asar.unpacked must be world-traversable and root-owned, or
# Cowork's auto-launch fs.existsSync() guard silently fails (#695).
unpacked_stat=$(stat -c '%a %U:%G' "$resources_dir/app.asar.unpacked")
if [[ $unpacked_stat == '755 root:root' ]]; then
	pass 'app.asar.unpacked is 755 root:root'
else
	fail "app.asar.unpacked is $unpacked_stat (want 755 root:root)"
fi

# --- Doctor smoke test ---
doctor_exit=0
/usr/bin/claude-desktop-unofficial --doctor >/dev/null 2>&1 \
	|| doctor_exit=$?
if [[ $doctor_exit -lt 127 ]]; then
	pass "--doctor runs without crashing (exit: $doctor_exit)"
else
	fail "--doctor crashed (exit: $doctor_exit)"
fi

# --- Headless launch smoke test ---
# The container runs as root; Electron aborts as root without
# --no-sandbox (which the launcher only adds on Wayland/deb), so drop to
# a throwaway unprivileged user. The install is world-readable and
# chrome-sandbox is setuid root, so this exercises the real sandbox path
# a Fedora user hits. The user is removed by the EXIT trap.
# In a non-root env or without useradd, smoke_user stays empty and the
# helper runs the launch as-is rather than dropping privileges.
smoke_user=''
if [[ $(id -u) -eq 0 ]] && command -v useradd &>/dev/null; then
	smoke_user='claude-smoke'
	useradd -m "$smoke_user" 2>/dev/null \
		|| smoke_user=''
fi

run_launch_smoke_test 'rpm package' '/usr/lib/claude-desktop-unofficial' \
	"$smoke_user" /usr/bin/claude-desktop-unofficial

print_summary
