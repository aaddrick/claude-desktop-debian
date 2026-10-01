#!/usr/bin/env bats
#
# _resolve_asar, the shared resolver in scripts/_common.sh.
#
# The failure this exists to prevent is not "asar is missing" — it is
# "asar is present and does not run". @electron/asar 4.x declares
# engines.node >=22.12.0 and refuses to start below it, npm downgrades
# that to an EBADENGINE warning, and the wrapper lands on disk anyway.
# Callers then fail three stages downstream on whatever they read out of
# a tree that was never extracted — the phantom "desktopName is
# missing/empty" WM_CLASS failure in #839.
#
# #841 closed that for the build (a Node floor plus a run-check in
# setup_asar); #846 gave the three non-build callers one shared
# resolver. #849 is the remaining arm: a PATH asar that fails the
# run-check now falls through to the pinned install instead of stopping,
# because that install is usually the fix for that exact binary. The
# invariant that has to survive every path is that an exit leaving the
# caller without an asar still names the Node floor — losing that is
# losing the whole point of #839.
#
# NOTE: setup() puts a FAILING npm stub on PATH. No test here may reach
# the real registry, so a test that wants a successful install has to
# say so with _stub_npm_install.

setup() {
	source "$BATS_TEST_DIRNAME/../scripts/_common.sh"

	# Every test resolves against a controlled PATH: the stub dir is
	# how a test decides whether `asar` and `npm` exist at all.
	stub_bin="$BATS_TEST_TMPDIR/bin"
	install_dir="$BATS_TEST_TMPDIR/install"
	mkdir -p "$stub_bin" "$install_dir"
	PATH="$stub_bin:$PATH"

	# Network-proof by default. Before #849 a dead PATH asar was
	# terminal, so the refusal tests never reached an install; now they
	# all fall through to one, and without this each would hit the live
	# registry from a unit test.
	_stub_npm_fail
}

# Put an executable `asar` on PATH. $1 = the stub's body.
_stub_asar_on_path() {
	printf '%s\n' '#!/usr/bin/env bash' "$1" > "$stub_bin/asar"
	chmod +x "$stub_bin/asar"
}

# Put an `npm` on PATH that records its argv to $BATS_TEST_TMPDIR/npm.args
# and drops a working asar wrapper where _resolve_asar will look for it.
# $1 = optional body for the installed wrapper (default: a good one).
_stub_npm_install() {
	local wrapper_body="${1:-echo 3.4.1}"
	cat > "$stub_bin/npm" <<-STUB
		#!/usr/bin/env bash
		printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/npm.args"
		mkdir -p "\$PWD/node_modules/.bin"
		printf '%s\n' '#!/usr/bin/env bash' '$wrapper_body' \
			> "\$PWD/node_modules/.bin/asar"
		chmod +x "\$PWD/node_modules/.bin/asar"
	STUB
	chmod +x "$stub_bin/npm"
}

# Put an `npm` on PATH that records its argv and then fails, standing in
# for an offline host, a proxy, or a yanked version.
_stub_npm_fail() {
	cat > "$stub_bin/npm" <<-STUB
		#!/usr/bin/env bash
		printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/npm.args"
		echo 'npm error code ENOTFOUND' >&2
		exit 1
	STUB
	chmod +x "$stub_bin/npm"
}

# ---------------------------------------------------------------------
# _asar_probe: the run-check itself
# ---------------------------------------------------------------------

@test "probe: a working asar passes and reports its version" {
	_stub_asar_on_path 'echo 3.4.1'

	_asar_probe "$stub_bin/asar" || return 1
	[[ $_asar_probe_version == '3.4.1' ]]
}

@test "probe: a leading v is accepted (real asar prints v3.4.1)" {
	# Not cosmetic — the shipped 3.4.1 wrapper answers `v3.4.1`, so a
	# shape regex without the optional v rejects the version we pin.
	_stub_asar_on_path 'echo v3.4.1'

	_asar_probe "$stub_bin/asar" || return 1
	[[ $_asar_probe_version == 'v3.4.1' ]]
}

@test "probe: an asar that exits non-zero fails" {
	# The observed shape: @electron/asar 4.3.0 under Node 20.19.2 exits
	# 1 with an empty stdout and its complaint on stderr.
	_stub_asar_on_path 'echo "CANNOT RUN WITH NODE 20.19.2" >&2; exit 1'

	if _asar_probe "$stub_bin/asar"; then return 1; fi
}

@test "probe: a version-shaped reply on a non-zero exit still fails" {
	# The half the stdout-shape arm cannot see. Without this, the
	# exit-code arm could be deleted with every other test staying
	# green.
	_stub_asar_on_path 'echo 3.4.1; exit 1'

	if _asar_probe "$stub_bin/asar"; then return 1; fi
}

@test "probe: a refusal that exits zero still fails" {
	# An exit code is not a contract. Note the refusal text quotes the
	# offending Node version, so an unanchored "contains a version
	# number" match passes it too — the reply has to be judged from its
	# start.
	_stub_asar_on_path \
		'echo "CANNOT RUN WITH NODE 20.19.2"; echo "needs >=22.12.0."'

	if _asar_probe "$stub_bin/asar"; then return 1; fi
}

@test "probe: the same refusal on stderr at exit zero still fails" {
	# Which stream the refusal takes is upstream's choice; an empty
	# stdout must fail the shape check with no help from the exit code.
	_stub_asar_on_path 'echo "CANNOT RUN WITH NODE 20.19.2" >&2'

	if _asar_probe "$stub_bin/asar"; then return 1; fi
}

@test "probe: noise on stderr does not fail a working asar" {
	# The judgment reads stdout precisely so a Node deprecation notice
	# can't red a host where asar runs fine.
	_stub_asar_on_path \
		'echo "(node:1) DeprecationWarning: whatever" >&2; echo 3.4.1'

	_asar_probe "$stub_bin/asar" || return 1
	[[ $_asar_probe_version == '3.4.1' ]]
}

@test "probe: the merged report keeps stderr for the operator" {
	# stdout is what gets judged; the report is what gets printed. If
	# the report dropped stderr, the refusal text — the only thing
	# naming the offending Node version — would never reach anyone.
	_stub_asar_on_path 'echo "CANNOT RUN WITH NODE 20.19.2" >&2; exit 1'

	if _asar_probe "$stub_bin/asar"; then return 1; fi
	[[ $_asar_probe_report == *'CANNOT RUN'* ]]
}

@test "probe: a non-executable candidate fails before it is run" {
	: > "$install_dir/asar"
	chmod 644 "$install_dir/asar"

	if _asar_probe "$install_dir/asar"; then return 1; fi
	[[ $_asar_probe_report == *'not executable'* ]]
}

# ---------------------------------------------------------------------
# The fallback
# ---------------------------------------------------------------------

@test "fallback: a dead PATH asar falls through to the pinned install" {
	# The #849 host: Debian 13 (Node 20) carrying a stale global 4.x
	# from an npm 9 that took `latest`. The install two lines down is
	# the fix for that exact binary, so stopping at the refusal leaves
	# the machine broken for no reason.
	_stub_asar_on_path 'echo "CANNOT RUN WITH NODE 20.19.2" >&2; exit 1'
	_stub_npm_install

	run _resolve_asar "$install_dir"
	[[ $status -eq 0 ]] || return 1
	[[ $output == *'will not run'* ]] || return 1
	[[ $output == *'Falling back'* ]] || return 1
	[[ $output == *'3.4.1'* ]]
}

@test "fallback: the fallen-back resolver publishes the installed asar" {
	# Not the dead PATH one. $asar_exec is the entire output of this
	# function; reporting success while leaving the caller pointed at
	# the refusing binary would be worse than stopping.
	_stub_asar_on_path 'echo "CANNOT RUN WITH NODE 20.19.2" >&2; exit 1'
	_stub_npm_install

	_resolve_asar "$install_dir" > /dev/null 2>&1 || return 1
	[[ $asar_exec == "$install_dir/node_modules/.bin/asar" ]]
}

@test "fallback: a working PATH asar wins with no install attempted" {
	# Installing on top of a usable host asar would be wasted network
	# and would hide a deliberately staged tool. Only a tool that
	# cannot RUN gets overridden.
	_stub_asar_on_path 'echo 9.9.9'
	_stub_npm_install

	run _resolve_asar "$install_dir"
	[[ $status -eq 0 ]] || return 1
	[[ $output == *'9.9.9'* ]] || return 1
	[[ $output != *'Falling back'* ]] || return 1
	[[ ! -e "$BATS_TEST_TMPDIR/npm.args" ]]
}

@test "fallback: when both fail, the PATH refusal leads the report" {
	# The design risk of the whole change. On an offline host a naive
	# fallback replaces the accurate "CANNOT RUN WITH NODE 20.19.2"
	# with "failed to install", which points at the network instead of
	# at the Node floor — strictly worse diagnosis for the same cause.
	# The root cause has to come first and has to still be there.
	_stub_asar_on_path 'echo "CANNOT RUN WITH NODE 20.19.2" >&2; exit 1'

	run _resolve_asar "$install_dir"
	[[ $status -ne 0 ]] || return 1
	[[ $output == *'CANNOT RUN WITH NODE 20.19.2'*'Failed to install'* ]]
}

@test "fallback: when both fail, the Node floor is still named" {
	# The #839 invariant. Any exit leaving the caller without an asar
	# must say it is a Node problem, or the operator goes hunting for a
	# patch anchor three stages downstream.
	_stub_asar_on_path 'echo "CANNOT RUN WITH NODE 20.19.2" >&2; exit 1'

	run _resolve_asar "$install_dir"
	[[ $status -ne 0 ]] || return 1
	[[ $output == *'22.12.0'* ]]
}

@test "fallback: a plain install failure also names the Node floor" {
	# Same invariant on the no-PATH-asar path, where there is no
	# refusal to lead with and the floor hint is the only diagnosis.
	run _resolve_asar "$install_dir"
	[[ $status -ne 0 ]] || return 1
	[[ $output == *'Failed to install'* ]] || return 1
	[[ $output == *'22.12.0'* ]]
}

@test "fallback: a dead install after a dead PATH asar reports both" {
	# Two different refusals, so the assertion can prove the ordering
	# rather than matching the same string twice.
	_stub_asar_on_path 'echo "PATH ASAR IS DEAD" >&2; exit 1'
	_stub_npm_install 'echo "INSTALLED ASAR IS DEAD" >&2; exit 1'

	run _resolve_asar "$install_dir"
	[[ $status -ne 0 ]] || return 1
	[[ $output == *'PATH ASAR IS DEAD'*'INSTALLED ASAR IS DEAD'* ]] \
		|| return 1
	[[ $output == *'22.12.0'* ]]
}

@test "fallback: an install that lands a dead wrapper is refused" {
	# The #839 shape end to end: npm reports EBADENGINE as a warning,
	# exits zero, and leaves a wrapper that refuses on every call.
	# Installing successfully is not the same as resolving, and there
	# is nothing left to fall back to, so this one must stop.
	_stub_npm_install 'echo "CANNOT RUN WITH NODE 20.19.2" >&2; exit 1'

	run _resolve_asar "$install_dir"
	[[ $status -ne 0 ]] || return 1
	[[ $output == *'will not run'* ]] || return 1
	[[ $output == *'22.12.0'* ]]
}

@test "fallback: a non-executable installed wrapper is refused" {
	# -x is the weaker of the two gates but still the first one: a
	# wrapper npm left unexecutable must not reach the version probe.
	cat > "$stub_bin/npm" <<-STUB
		#!/usr/bin/env bash
		mkdir -p "\$PWD/node_modules/.bin"
		: > "\$PWD/node_modules/.bin/asar"
		chmod 644 "\$PWD/node_modules/.bin/asar"
	STUB
	chmod +x "$stub_bin/npm"

	run _resolve_asar "$install_dir"
	[[ $status -ne 0 ]] || return 1
	[[ $output == *'not executable'* ]]
}

# ---------------------------------------------------------------------
# Argument guards
# ---------------------------------------------------------------------

@test "resolve asar: an empty install dir is refused, not silently used" {
	# A caller that forgets the argument must stop here rather than
	# npm-installing into whatever directory it happens to sit in.
	run _resolve_asar ''
	[[ $status -ne 0 ]] || return 1
	[[ $output == *'no install directory'* ]]
}

@test "resolve asar: a missing install dir is named, not blamed on npm" {
	# The install subshell cd's into it, so without this the operator
	# reads "Failed to install @electron/asar@3" for a directory that
	# was never created.
	run _resolve_asar "$BATS_TEST_TMPDIR/nope"
	[[ $status -ne 0 ]] || return 1
	[[ $output == *'not a directory'* ]]
}

# ---------------------------------------------------------------------
# The pin
# ---------------------------------------------------------------------

@test "resolve asar: the install pins a major instead of taking latest" {
	# Whether an unpinned install lands on the Node-20-hostile 4.x
	# depends on the npm version (npm 9 takes `latest`; npm 10's
	# manifest picker skips engine-incompatible versions), so the
	# request must name the major.
	_stub_npm_install

	run _resolve_asar "$install_dir"
	[[ $status -eq 0 ]] || return 1
	[[ $(cat "$BATS_TEST_TMPDIR/npm.args") == *'@electron/asar@3'* ]]
}

@test "resolve asar: the pinned major is the caller's, not a constant" {
	_stub_npm_install

	run _resolve_asar "$install_dir" 4
	[[ $status -eq 0 ]] || return 1
	[[ $(cat "$BATS_TEST_TMPDIR/npm.args") == *'@electron/asar@4'* ]]
}

@test "resolve asar: the fallback install honours the caller's major" {
	# The fallback reaches the install through a second path; a pin
	# applied to only one of them would leave the stale-global host
	# resolving whatever `latest` is.
	_stub_asar_on_path 'echo "CANNOT RUN WITH NODE 20.19.2" >&2; exit 1'
	_stub_npm_install

	run _resolve_asar "$install_dir" 4
	[[ $status -eq 0 ]] || return 1
	[[ $(cat "$BATS_TEST_TMPDIR/npm.args") == *'@electron/asar@4'* ]]
}

# ---------------------------------------------------------------------
# The call sites
# ---------------------------------------------------------------------

@test "asar callers: no script reaches asar through npx" {
	# The regression this whole change exists to prevent. `npx --yes
	# @electron/asar` is unpinned (so it can land on a 4.x the host
	# cannot run) and, when the caller invokes "$asar_exec" as a single
	# word, it also turns the next argument into a PACKAGE name.
	# Comment lines are stripped: the resolver and both call sites
	# explain in prose what they no longer do, and those sentences are
	# the record of why, not a hit. The pattern is split across two
	# adjacent quoted words so this line does not match itself.
	local hits
	hits=$(grep -rn --include='*.sh' --include='*.bats' \
		-- 'npx .*@electron''/asar' "$BATS_TEST_DIRNAME/.." \
		| grep -v ':[[:space:]]*#') || true
	[[ -z $hits ]]
}

@test "asar callers: the audit tool resolves before it extracts" {
	local src="$BATS_TEST_DIRNAME/../tools/patch-necessity-audit.sh"
	grep -q '_resolve_asar "\$work_dir"' "$src" || return 1
	# Quoted: an unquoted $asar_exec was what let a multi-word `npx …`
	# value masquerade as a single command in the first place.
	grep -q '"\$asar_exec" extract' "$src"
}

@test "asar callers: the artifact tests resolve before they extract" {
	local src="$BATS_TEST_DIRNAME/test-artifact-common.sh"
	grep -q '_resolve_asar "\$extract_dir"' "$src" || return 1
	grep -q '"\$asar_exec" extract' "$src"
}

@test "asar callers: the patch-stage harness keeps no private copy" {
	# It had the only implementation; leaving it behind would shadow
	# the shared one (it sources _common.sh first) and let the two
	# drift apart silently.
	run grep -c '^_resolve_asar() {' \
		"$BATS_TEST_DIRNAME/test-patch-stage.sh"
	[[ $status -ne 0 ]] || return 1
	grep -q '_resolve_asar "\$work_dir"' \
		"$BATS_TEST_DIRNAME/test-patch-stage.sh"
}

@test "artifact tests: a resolved asar actually reaches the extract" {
	# The happy path, and the one the two negative cases below cannot
	# see. _resolve_asar publishes $asar_exec as a global, so capturing
	# it with $(...) would run it in a subshell, discard the assignment,
	# and leave the extract invoking the empty string — which fails, so
	# the negative cases stay green on the wrong cause. Only an extract
	# that has to succeed pins it. (The
	# subshell-discards-the-mutation class from
	# docs/learnings/test-methodology-and-coverage.md.)
	_stub_asar_on_path 'case "$1" in
		--version) echo 3.4.1 ;;
		extract)
			mkdir -p "$3/.vite/build"
			printf "%s\\n" "{\"main\": \".vite/build/index.js\"," \\
				"\"productName\": \"Claude\"," \\
				"\"desktopName\": \"claude-desktop-unofficial.desktop\"}" \\
				> "$3/package.json"
			: > "$3/.vite/build/index.js"
			;;
		*) exit 1 ;;
	esac'
	source "$BATS_TEST_DIRNAME/test-artifact-common.sh"

	local resources="$BATS_TEST_TMPDIR/resources"
	mkdir -p "$resources/app.asar.unpacked"
	: > "$resources/app.asar"

	run validate_app_contents "$resources"
	[[ $output != *'extract failed'* ]] || return 1
	[[ $output == *'[PASS]'*'productName is Claude'* ]]
}

@test "artifact tests: a failed extract fails instead of passing" {
	# The other half of the old skip branch. An asar that answers
	# --version and then cannot read the archive gets past the
	# resolver, so the extract's own exit code is the last thing
	# standing between a corrupt app.asar and a green suite.
	_stub_asar_on_path \
		'case "$1" in --version) echo 3.4.1 ;; *) exit 1 ;; esac'
	source "$BATS_TEST_DIRNAME/test-artifact-common.sh"

	local resources="$BATS_TEST_TMPDIR/resources"
	mkdir -p "$resources/app.asar.unpacked"
	: > "$resources/app.asar"

	run validate_app_contents "$resources"
	[[ $output != *'Skipping asar extraction'* ]] || return 1
	[[ $output == *'[FAIL]'*'asar extract failed'* ]]
}

@test "artifact tests: an unresolvable asar fails instead of skipping" {
	# The old code reported [PASS] "Skipping asar extraction" when the
	# tool was unusable, which silently dropped every assertion behind
	# it — package.json shape, productName, and the
	# StartupWMClass/desktopName agreement that closes #779. A suite
	# that goes green on nothing read is worse than one that goes red.
	# npm fails here (setup's default), so the #849 fallback cannot
	# rescue this one and the caller must still see a failure.
	_stub_asar_on_path 'echo "CANNOT RUN WITH NODE 20.19.2" >&2; exit 1'
	source "$BATS_TEST_DIRNAME/test-artifact-common.sh"

	local resources="$BATS_TEST_TMPDIR/resources"
	mkdir -p "$resources/app.asar.unpacked"
	: > "$resources/app.asar"

	run validate_app_contents "$resources"
	[[ $output != *'Skipping asar extraction'* ]] || return 1
	[[ $output == *'[FAIL]'*'Could not resolve a runnable asar'* ]]
}
