#!/usr/bin/env bats
#
# The build's Node floor is not ours to pick: @electron/asar 4.x declares
# engines.node >=22.12.0 and refuses to start below it, while npm only
# emits an EBADENGINE *warning* and installs the wrapper anyway. On a
# Node 20 host that combination used to produce an asar that existed,
# never ran, and surfaced three stages later as the WM_CLASS tripwire
# ("desktopName is missing/empty"), which reads like a broken patch
# rather than a broken toolchain (#839).
#
# Two things are pinned here. node_version_at_least must reject the
# 22.0-22.11 band that a major-only comparison waves through, and
# setup_asar must fail at the point of install when the binary cannot
# execute. The shape that ships today is an exit of 1 with the
# complaint on stderr; the stdout-shape arm is defense in depth for a
# future release that answers through --version and exits zero.

setup() {
	source "$BATS_TEST_DIRNAME/../scripts/_common.sh"
	source "$BATS_TEST_DIRNAME/../scripts/setup/dependencies.sh"
}

# ---------------------------------------------------------------------
# node_version_at_least
# ---------------------------------------------------------------------

@test "node floor: the shipped fallback download satisfies the floor" {
	# A floor bump that forgets the fallback leaves setup_nodejs
	# downloading a Node its own gate would have rejected.
	node_version_at_least "$NODE_FALLBACK_VERSION" "$NODE_MIN_VERSION"
}

@test "node floor: the floor is the asar engine constraint" {
	# Documented so a drive-by relax of NODE_MIN_VERSION has to argue
	# with a red test rather than a comment.
	[[ $NODE_MIN_VERSION == '22.12.0' ]]
}

@test "node version: Debian 13 stable's Node 20 is rejected" {
	# The reported host in #839.
	! node_version_at_least '20.19.2' "$NODE_MIN_VERSION" || return 1
}

@test "node version: the 22.0-22.11 band is rejected" {
	# The case a major-only comparison gets wrong.
	! node_version_at_least '22.11.9' "$NODE_MIN_VERSION" || return 1
	! node_version_at_least '22.0.0' "$NODE_MIN_VERSION" || return 1
}

@test "node version: the floor itself is accepted" {
	node_version_at_least '22.12.0' "$NODE_MIN_VERSION"
}

@test "node version: a newer minor and a newer major are accepted" {
	node_version_at_least '22.23.2' "$NODE_MIN_VERSION"
	node_version_at_least '24.20.0' "$NODE_MIN_VERSION"
}

@test "node version: a bare major below the floor's major is rejected" {
	! node_version_at_least '20' "$NODE_MIN_VERSION" || return 1
}

@test "node version: a bare major equal to the floor's is rejected" {
	# "22" carries no minor, so it cannot be shown to clear 22.12 —
	# treat the absent component as 0 rather than as "close enough".
	! node_version_at_least '22' "$NODE_MIN_VERSION" || return 1
}

@test "node version: unparseable input is rejected, not arithmetic-evaluated" {
	# Bare (( )) on these would either error or silently read them as 0;
	# neither is an answer we should hand the gate.
	! node_version_at_least '' "$NODE_MIN_VERSION" || return 1
	! node_version_at_least 'v22.12.0' "$NODE_MIN_VERSION" || return 1
	! node_version_at_least 'nightly' "$NODE_MIN_VERSION" || return 1
	! node_version_at_least '22.12.0' 'nightly' || return 1
}

@test "node version: input that arithmetic would clear the floor is rejected" {
	# The cases above all read as 0 under a bare (( )), so they are
	# rejected with or without the regex and cannot pin it. These clear
	# the floor if they ever reach the arithmetic: (( 0x18 )) is 24 in
	# base 16 and (( 22+1 )) is an expression, not a version. Whatever
	# handed us one of these was not reporting a Node version, so the
	# answer is "can't vouch for it", not "24 >= 22".
	! node_version_at_least '0x18' "$NODE_MIN_VERSION" || return 1
	! node_version_at_least '22+1' "$NODE_MIN_VERSION" || return 1
	! node_version_at_least '22.12.0' '0x18' || return 1
}

# ---------------------------------------------------------------------
# setup_asar's run-check
# ---------------------------------------------------------------------

# Stage a work dir holding a stub asar at the path setup_asar resolves,
# so the npm install branch is skipped. $1 = the stub's body.
_stage_asar_stub() {
	work_dir="$BATS_TEST_TMPDIR/work"
	project_root="$BATS_TEST_TMPDIR"
	mkdir -p "$work_dir/node_modules/.bin"
	printf '%s\n' '#!/usr/bin/env bash' "$1" \
		> "$work_dir/node_modules/.bin/asar"
	chmod +x "$work_dir/node_modules/.bin/asar"
}

@test "setup_asar: a working asar is accepted and reported" {
	_stage_asar_stub 'echo 4.3.0'

	run setup_asar
	[[ $status -eq 0 ]]
	[[ $output == *'4.3.0'* ]]
}

@test "setup_asar: an asar that exits non-zero fails the build" {
	# The observed shape: @electron/asar 4.3.0 under Node 20.19.2 exits
	# 1 with an empty stdout and its complaint on stderr.
	_stage_asar_stub \
		'echo "CANNOT RUN WITH NODE 20.19.2" >&2; exit 1'

	run setup_asar
	[[ $status -ne 0 ]]
	[[ $output == *'will not run'* ]]
}

@test "setup_asar: a version-shaped reply on a non-zero exit still fails" {
	# The half the shape check can't see. A tool that answers correctly
	# and then exits non-zero is not a tool the patch stage should be
	# handed, and without this the exit-code arm of the guard could be
	# deleted with every other test staying green.
	_stage_asar_stub 'echo 4.3.0; exit 1'

	run setup_asar
	[[ $status -ne 0 ]]
	[[ $output == *'will not run'* ]]
}

@test "setup_asar: a refusal that exits zero would still fail the build" {
	# Not what 4.3.0 does today — it exits 1 — but an exit code is not a
	# contract, and a refusal routed through --version at exit zero
	# would hand the patch stage a dead binary if the exit code were the
	# only arm. Note the refusal text quotes the offending Node version,
	# so an unanchored "contains a version number" match passes it too —
	# the reply has to be judged from its start.
	_stage_asar_stub \
		'echo "CANNOT RUN WITH NODE 20.19.2"; echo "asar requires Node >=22.12.0."; exit 0'

	run setup_asar
	[[ $status -ne 0 ]]
	[[ $output == *'will not run'* ]]
}

@test "setup_asar: the same refusal on stderr also fails the build" {
	# Which stream the refusal takes is upstream's choice, not a
	# contract; an empty stdout must fail the shape check on its own,
	# with no help from the exit code.
	_stage_asar_stub 'echo "CANNOT RUN WITH NODE 20.19.2" >&2; exit 0'

	run setup_asar
	[[ $status -ne 0 ]]
	[[ $output == *'will not run'* ]]
}

@test "setup_asar: noise on stderr does not fail a working asar" {
	# The judgment reads stdout precisely so an npm/Node deprecation
	# notice can't red the build on a host where asar runs fine.
	_stage_asar_stub 'echo "(node:1) DeprecationWarning: whatever" >&2; echo 4.3.0'

	run setup_asar
	[[ $status -eq 0 ]]
	[[ $output == *'4.3.0'* ]]
}

@test "setup_asar: the failure names the Node floor, not just the tool" {
	# The whole point of the check is that the operator learns it is a
	# Node problem here rather than guessing at a patch anchor later.
	_stage_asar_stub 'exit 1'

	run setup_asar
	[[ $output == *"$NODE_MIN_VERSION"* ]]
}
