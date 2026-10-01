#!/usr/bin/env bats
#
# deb-apport-blacklist.bats
# The deb ships an apport crash blacklist, as a registered conffile.
#
# On Ubuntu, core_pattern pipes every crash to apport, which writes a
# multi-megabyte report that update-notifier-crash then floods into the
# journal and on to /var/log/syslog. A crash-looping Electron drove that
# to 190 GB for one reporter (#582). The deb breaks the loop by listing
# our binaries in apport's drop-in directory. Nothing else asserts the
# file is emitted, or that it is a conffile, so a refactor of deb.sh
# could drop either half and stay green until a user's disk fills.
#
# Verification tier: this is the cheap static one. It reads the source of
# scripts/packaging/deb.sh, not a built package — it pins that deb.sh
# *emits* the file and the conffiles entry with paths derived from
# $package_name. That the built .deb actually carries the file and dpkg
# treats it as a conffile is the real-package leg in
# tests/test-artifact-deb.sh, which runs against an installed artifact.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
DEB_SH="${SCRIPT_DIR}/../scripts/packaging/deb.sh"

# The two executables apport must ignore. Both are written into the
# blacklist as `/usr/lib/$package_name/<name>`; the test checks the
# `$package_name` form, not the expanded `claude-desktop-unofficial`, so
# a rename that forgets these lines cannot pass by matching a stale
# literal. The main ELF's children (zygote, renderer, gpu) re-exec the
# same path, so it covers the whole Chromium tree; the crashpad handler
# is a separate binary that can crash on its own.
readonly BLACKLISTED_BINARIES=(
	claude-desktop
	chrome_crashpad_handler
)

# deb.sh with full-line comments stripped, so a `#` line that merely
# names a path or `conffiles` cannot satisfy an assertion. The apport
# block carries a long rationale comment that mentions both binaries.
uncommented() {
	grep -vE '^[[:space:]]*#' "${DEB_SH}" || true
}

@test "deb.sh is present and its uncommented body is non-empty" {
	# Guards every test below: a renamed or vanished script would
	# otherwise pass them all on empty input.
	[[ -s "${DEB_SH}" ]]
	[[ -n "$(uncommented)" ]]
}

@test "deb.sh writes the blacklist under etc/apport/blacklist.d" {
	# The install target, keyed on $package_name so it tracks the
	# package rename. The `$package_root/etc/...` prefix (a sibling of
	# usr/) is what puts the file at /etc once installed.
	uncommented | grep -qE \
		'package_root/etc/apport/blacklist\.d/\$(\{)?package_name'
}

@test "the blacklist lists both binaries, keyed to \$package_name" {
	local body binary
	body="$(uncommented)"
	for binary in "${BLACKLISTED_BINARIES[@]}"; do
		# `/usr/lib/$package_name/<binary>` — the installed absolute
		# path, not the build-tree one, and $package_name not a literal.
		grep -qE "/usr/lib/\\\$(\\{)?package_name(\\})?/${binary}\$" \
			<<<"$body" || {
			printf 'blacklist is missing %s\n' "$binary" >&2
			return 1
		}
	done
}

@test "the blacklist path is registered as a conffile" {
	# dpkg-deb --build (unlike debhelper) does not auto-register /etc
	# files as conffiles, so the DEBIAN/conffiles entry is what makes an
	# admin edit survive upgrade. Same $package_name-derived path.
	local body
	body="$(uncommented)"
	# A write to DEBIAN/conffiles ...
	grep -qE '>[[:space:]]*"\$(\{)?package_root(\})?/DEBIAN/conffiles"' \
		<<<"$body"
	# ... whose payload is the blacklist path. Anchored to the `echo`
	# statement itself, not matched loose against the whole body: the
	# same path appears on the `install -D` target line, so a loose grep
	# stays green even when the conffiles echo points somewhere else
	# (caught only by the artifact leg otherwise).
	grep -qE \
		'^[[:space:]]*echo "/etc/apport/blacklist\.d/\$(\{)?package_name(\})?"' \
		<<<"$body"
}

@test "the blacklist file carries no comment lines" {
	# apport reads every line of a blacklist as an executable path; a
	# `#` line would be a bogus path that never matches — harmless but
	# wrong. Assert the two heredoc payload lines are bare paths. The
	# heredoc body is the run of `/usr/lib/...` lines; neither starts
	# with `#`.
	local hd
	hd="$(awk '
		/install -Dm 644 \/dev\/stdin/ { grab = 1 }
		grab && /^EOF$/ { exit }
		grab && /^\/usr\/lib\// { print }
	' "${DEB_SH}")"
	[[ -n "$hd" ]]
	! grep -qE '^[[:space:]]*#' <<<"$hd"
}
