#!/usr/bin/env bats
#
# triage-validate.bats
# Tests for path handling in .claude/scripts/triage/validate.sh.
#
# resolve_path turns LLM-produced finding paths into filesystem
# paths, so it is a security chokepoint: absolute paths, `..`
# traversal, and `.git/` internals must resolve to empty (the
# caller's `[[ -f ]]` check then fails the finding). validate.sh is
# a script, not a library — sourcing it would run the pipeline — so
# the function is extracted by its comment-fenced block.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
VALIDATE_SH="${SCRIPT_DIR}/../.claude/scripts/triage/validate.sh"

setup() {
	repo_root='/repo'
	reference_root='/ref'
	source <(sed -n '/^resolve_path()/,/^}/p' "${VALIDATE_SH}")
}

@test "repo-relative path resolves under repo root" {
	run resolve_path 'scripts/build.sh'
	[[ "$output" == '/repo/scripts/build.sh' ]]
}

@test "reference-source path resolves under reference root" {
	run resolve_path 'reference-source/.vite/build/index.js'
	[[ "$output" == '/ref/.vite/build/index.js' ]]
}

@test "dotfiles that are not .git still resolve" {
	run resolve_path '.github/workflows/ci.yml'
	[[ "$output" == '/repo/.github/workflows/ci.yml' ]]
	run resolve_path '.gitignore'
	[[ "$output" == '/repo/.gitignore' ]]
}

@test "absolute path is rejected" {
	run resolve_path '/etc/passwd'
	[[ -z "$output" ]]
	[[ "$status" -eq 0 ]]
}

@test "dot-dot traversal is rejected in every position" {
	local p
	for p in '..' '../x' 'a/..' 'a/../b'; do
		run resolve_path "$p"
		[[ -z "$output" ]]
	done
}

@test ".git internals are rejected at any depth" {
	local p
	for p in '.git' '.git/config' 'sub/.git' 'sub/.git/config'; do
		run resolve_path "$p"
		[[ -z "$output" ]]
	done
}

@test "rejection exits zero so errexit substitutions survive" {
	# validate.sh runs under errexit; resolve_path must never return
	# nonzero or `resolved=$(resolve_path ...)` would abort the run.
	run bash -o errexit -c "
		repo_root=/repo reference_root=/ref
		$(sed -n '/^resolve_path()/,/^}/p' "${VALIDATE_SH}")
		resolved=\$(resolve_path '/etc/passwd')
		echo \"survived:\${resolved}\"
	"
	[[ "$status" -eq 0 ]]
	[[ "$output" == 'survived:' ]]
}
