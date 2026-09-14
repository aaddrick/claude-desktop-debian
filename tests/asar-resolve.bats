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
# setup_asar). Two callers reached asar through an unpinned
# `npx --yes @electron/asar` instead, outside setup_nodejs's reach:
# tools/patch-necessity-audit.sh and tests/test-artifact-common.sh.
# Both now share tests/test-patch-stage.sh's resolver, so the resolver
# itself is pinned here once, and each call site is pinned for the two
# properties a shared helper cannot enforce for it: that it calls the
# resolver at all, and that no npx path survives beside it.

setup() {
	source "$BATS_TEST_DIRNAME/../scripts/_common.sh"

	# Every test resolves against a controlled PATH: the stub dir is
	# how a test decides whether `asar` and `npm` exist at all.
	stub_bin="$BATS_TEST_TMPDIR/bin"
	install_dir="$BATS_TEST_TMPDIR/install"
	mkdir -p "$stub_bin" "$install_dir"
	PATH="$stub_bin:$PATH"
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

# ---------------------------------------------------------------------
# The run-check
# ---------------------------------------------------------------------

@test "resolve asar: a working asar on PATH is accepted and reported" {
	_stub_asar_on_path 'echo 3.4.1'

	run _resolve_asar "$install_dir"
	[[ $status -eq 0 ]] || return 1
	[[ $output == *'3.4.1'* ]]
}

@test "resolve asar: an asar that exits non-zero is refused" {
	# The observed shape: @electron/asar 4.3.0 under Node 20.19.2 exits
	# 1 with an empty stdout and its complaint on stderr.
	_stub_asar_on_path 'echo "CANNOT RUN WITH NODE 20.19.2" >&2; exit 1'

	run _resolve_asar "$install_dir"
	[[ $status -ne 0 ]] || return 1
	[[ $output == *'will not run'* ]]
}

@test "resolve asar: a version-shaped reply on a non-zero exit is refused" {
	# The half the stdout-shape arm cannot see. Without this, the
	# exit-code arm could be deleted with every other test staying
	# green.
	_stub_asar_on_path 'echo 3.4.1; exit 1'

	run _resolve_asar "$install_dir"
	[[ $status -ne 0 ]] || return 1
	[[ $output == *'will not run'* ]]
}

@test "resolve asar: a refusal that exits zero is refused" {
	# An exit code is not a contract. Note the refusal text quotes the
	# offending Node version, so an unanchored "contains a version
	# number" match passes it too — the reply has to be judged from its
	# start.
	_stub_asar_on_path \
		'echo "CANNOT RUN WITH NODE 20.19.2"; echo "needs >=22.12.0."'

	run _resolve_asar "$install_dir"
	[[ $status -ne 0 ]] || return 1
	[[ $output == *'will not run'* ]]
}

@test "resolve asar: the same refusal on stderr at exit zero is refused" {
	# Which stream the refusal takes is upstream's choice; an empty
	# stdout must fail the shape check with no help from the exit code.
	_stub_asar_on_path 'echo "CANNOT RUN WITH NODE 20.19.2" >&2'

	run _resolve_asar "$install_dir"
	[[ $status -ne 0 ]] || return 1
	[[ $output == *'will not run'* ]]
}

@test "resolve asar: noise on stderr does not refuse a working asar" {
	# The judgment reads stdout precisely so a Node deprecation notice
	# can't red a host where asar runs fine.
	_stub_asar_on_path \
		'echo "(node:1) DeprecationWarning: whatever" >&2; echo 3.4.1'

	run _resolve_asar "$install_dir"
	[[ $status -eq 0 ]] || return 1
	[[ $output == *'3.4.1'* ]]
}

@test "resolve asar: the refusal names the Node floor, not just the tool" {
	# The point of the check is that the operator learns it is a Node
	# problem here rather than guessing at a patch anchor later.
	_stub_asar_on_path 'exit 1'

	run _resolve_asar "$install_dir"
	[[ $status -ne 0 ]] || return 1
	[[ $output == *'22.12.0'* ]]
}

@test "resolve asar: a non-executable resolved binary is refused" {
	# -x is the weaker of the two gates but still the first one: a
	# wrapper that npm left unexecutable must not reach the probe.
	_stub_npm_install
	chmod -x "$stub_bin/npm" 2>/dev/null
	mkdir -p "$install_dir/node_modules/.bin"
	: > "$install_dir/node_modules/.bin/asar"
	chmod 644 "$install_dir/node_modules/.bin/asar"
	# npm is a no-op here (not executable is enough to skip the
	# install), so point the resolver straight at the bad wrapper.
	printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$stub_bin/npm"
	chmod +x "$stub_bin/npm"

	run _resolve_asar "$install_dir"
	[[ $status -ne 0 ]] || return 1
	[[ $output == *'not executable'* ]]
}

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
	_stub_npm_install

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

@test "resolve asar: an asar on PATH wins over an install" {
	# Installing on top of a usable host asar would be wasted network
	# and would hide a deliberately staged tool.
	_stub_asar_on_path 'echo 9.9.9'
	_stub_npm_install

	run _resolve_asar "$install_dir"
	[[ $status -eq 0 ]] || return 1
	[[ $output == *'9.9.9'* ]] || return 1
	[[ ! -e "$BATS_TEST_TMPDIR/npm.args" ]]
}

@test "resolve asar: a wrapper that installs but cannot run is refused" {
	# The whole #839 shape end to end: npm reports EBADENGINE as a
	# warning, exits zero, and leaves a wrapper that refuses on every
	# call. Installing successfully is not the same as resolving.
	_stub_npm_install 'echo "CANNOT RUN WITH NODE 20.19.2" >&2; exit 1'

	run _resolve_asar "$install_dir"
	[[ $status -ne 0 ]] || return 1
	[[ $output == *'will not run'* ]]
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
	_stub_asar_on_path 'echo "CANNOT RUN WITH NODE 20.19.2" >&2; exit 1'
	source "$BATS_TEST_DIRNAME/test-artifact-common.sh"

	local resources="$BATS_TEST_TMPDIR/resources"
	mkdir -p "$resources/app.asar.unpacked"
	: > "$resources/app.asar"

	run validate_app_contents "$resources"
	[[ $output != *'Skipping asar extraction'* ]] || return 1
	[[ $output == *'[FAIL]'*'Could not resolve a runnable asar'* ]]
}
