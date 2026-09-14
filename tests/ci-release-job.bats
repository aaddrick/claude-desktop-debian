#!/usr/bin/env bats
#
# ci-release-job.bats
# Structural invariants for the "Create Release" job in
# .github/workflows/ci.yml.
#
# The release job is a chokepoint: mirror-official-deb, update-apt-repo,
# update-dnf-repo and update-aur-repo all carry `needs: [release]`, so a
# step that fails the job also withholds the release from every channel.
#
# On 2026-07-24 the claude-desktop-versions repo went private. Its
# checkout is `continue-on-error: true`, so it rendered as a green check
# while its `outcome` was failure — which skipped the four steps gated on
# that outcome, one of which installed asar for the entirely unrelated
# reference-source step. That step exited 127 (`asar: command not
# found`), failed the job, and the publish jobs never ran.
#
# These tests pin the decoupling: reference-source tooling installs
# unconditionally, and the step degrades to a warning if a tool is
# missing anyway.
#
# No YAML library is used — awk splits the job on its step boundaries,
# which keeps the suite on the bash/awk toolchain the rest of tests/ uses
# and adds no dependency. The parser is deliberately fragile in the
# visible direction: "the parser sees the expected shape" fails loudly if
# the indentation it keys on ever drifts, and every test below asserts
# its step block was actually found before reading anything out of it, so
# a vanished step reds the suite instead of passing on empty output.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
CI_YML="${SCRIPT_DIR}/../.github/workflows/ci.yml"

# The release job's region: everything between the `  release:` job
# header and the next job header at the same indent.
release_region() {
	awk '
		/^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
			inj = ($0 == "  release:")
			next
		}
		inj { print }
	' "$CI_YML"
}

# Every release-job step block whose body contains <1>. A block runs from
# its own `      - ` line up to the next step's.
step_blocks() {
	release_region | awk -v pat="$1" '
		/^      - / {
			if (started && hit) printf "%s", buf
			started = 1; buf = ""; hit = 0
		}
		started {
			buf = buf $0 "\n"
			if (index($0, pat)) hit = 1
		}
		END { if (started && hit) printf "%s", buf }
	'
}

# The step keys of a block, comments stripped, so a `#` line mentioning a
# command cannot stand in for the command itself.
uncommented() {
	grep -vE '^[[:space:]]*#' || true
}

# The `needs:` line of job <1>.
job_needs_line() {
	awk -v job="  $1:" '
		$0 == job { inj = 1; next }
		/^  [A-Za-z0-9_-]+:[[:space:]]*$/ { inj = 0 }
		inj && /^    needs:/ { print; exit }
	' "$CI_YML"
}

@test "the release-job parser sees the expected shape" {
	# If this reds, the awk key (6-space step indent, 2-space job header)
	# has drifted and every assertion below is reading nothing.
	local region steps
	region=$(release_region)
	[[ -n "$region" ]]

	steps=$(grep -c '^      - ' <<<"$region")
	[[ "$steps" -ge 15 ]]

	# Proves we are in the right job, and that the region stops at the
	# job boundary instead of bleeding into the publish jobs.
	[[ "$region" == *'Create GitHub Release'* ]]
	[[ "$region" != *'Update AUR Package'* ]]
}

@test "asar is installed by exactly one step" {
	local blocks
	blocks=$(step_blocks '@electron/asar' | grep -c '^      - ' || true)
	[[ "$blocks" -eq 1 ]]
}

@test "the asar install is not gated on the versions checkout" {
	local block cond
	block=$(step_blocks '@electron/asar')
	[[ -n "$block" ]]

	cond=$(uncommented <<<"$block" | grep '^        if:' || true)
	[[ "$cond" != *checkout_versions* ]]
}

@test "the asar install is not gated at all" {
	local block cond
	block=$(step_blocks '@electron/asar')
	[[ -n "$block" ]]

	cond=$(uncommented <<<"$block" | grep '^        if:' || true)
	[[ -z "$cond" ]]
}

@test "asar is not co-installed with release-notes-only tooling" {
	# Bundling asar back in with @anthropic-ai/claude-code is how the
	# coupling would silently return: that package is only used by the
	# compare-releases step, which is gated on the versions checkout.
	local block
	block=$(step_blocks '@electron/asar')
	[[ -n "$block" ]]

	run grep -qF '@anthropic-ai/claude-code' <<<"$block"
	[[ "$status" -ne 0 ]]
}

@test "node is set up before asar is installed, and is ungated" {
	local region node_ln asar_ln block cond
	region=$(release_region)
	node_ln=$(grep -n 'actions/setup-node' <<<"$region" \
		| head -1 | cut -d: -f1)
	asar_ln=$(grep -n '@electron/asar' <<<"$region" \
		| head -1 | cut -d: -f1)
	[[ -n "$node_ln" ]]
	[[ -n "$asar_ln" ]]
	[[ "$node_ln" -lt "$asar_ln" ]]

	block=$(step_blocks 'actions/setup-node')
	[[ -n "$block" ]]
	cond=$(uncommented <<<"$block" | grep '^        if:' || true)
	[[ -z "$cond" ]]
}

@test "the reference-source step guards asar before invoking it" {
	# A bare "the guard exists" grep would pass on a guard sitting after
	# the call, or on a comment mentioning it — so strip comments and pin
	# the ordering.
	local block guard_ln use_ln
	block=$(step_blocks 'reference-source.tar.gz' | uncommented)
	[[ -n "$block" ]]

	guard_ln=$(grep -n 'command -v asar' <<<"$block" | head -1 | cut -d: -f1)
	use_ln=$(grep -n 'asar extract' <<<"$block" | head -1 | cut -d: -f1)
	[[ -n "$guard_ln" ]]
	[[ -n "$use_ln" ]]
	[[ "$guard_ln" -lt "$use_ln" ]]
}

@test "every reference-source bail-out is a warning, not a failure" {
	# Three guards, three `exit 0`. A bail-out that fell through to a
	# non-zero exit would take the publish jobs down with it.
	local block warnings exits
	block=$(step_blocks 'reference-source.tar.gz' | uncommented)
	[[ -n "$block" ]]

	warnings=$(grep -c '::warning::' <<<"$block" || true)
	exits=$(grep -c 'exit 0' <<<"$block" || true)
	[[ "$warnings" -ge 3 ]]
	[[ "$exits" -eq "$warnings" ]]
}

@test "the publish jobs still depend on the release job" {
	# This is what makes a release-job failure expensive, and is the
	# premise every test above rests on.
	local job needs
	for job in mirror-official-deb update-apt-repo update-dnf-repo \
		update-aur-repo; do
		needs=$(job_needs_line "$job")
		[[ -n "$needs" ]]
		[[ "$needs" == *release* ]]
	done
}
