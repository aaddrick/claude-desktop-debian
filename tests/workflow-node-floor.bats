#!/usr/bin/env bats
#
# workflow-node-floor.bats
# Every workflow that installs floored tooling sets up a Node that can
# actually run it.
#
# ci.yml and issue-triage-v2.yml both `npm install -g`
# tools with a Node engine floor above 20: @electron/asar has declared
# engines.node >=22.12.0 since 4.0.0 and every 4.x release refuses to
# start below it, and @anthropic-ai/claude-code declares >=22.0.0.
#
# Neither install fails loudly on an older runtime. What happens depends
# on npm: a bare `npm install -g <name>` is a *range* spec (`*`), and
# npm-pick-manifest >=9.1.0 — which npm bundles from 10.8.2 — stops
# short-circuiting a `*` range to the `latest` dist-tag when its engines
# mismatch. So on Node 20 npm silently resolves asar to 3.4.1 and the
# claude-code CLI to 2.1.197 (>=18.0.0) rather than refusing. Older npm
# keeps the shortcut: it resolves 4.3.0, and the EBADENGINE mismatch is
# only a *warning*, so the wrapper installs and then dies on every
# invocation. Node 20.19.2 bundles npm 10.8.2, so a runner clears that
# boundary by one patch release — which is the whole reason the outcome
# was the runner's to decide rather than ours.
#
# Both outcomes are bugs and neither announces itself: one silently runs
# a CLI pinned dozens of releases back, the other leaves a binary that
# `command -v` finds and that cannot start. Asserting the runtime here
# is what makes the resolved version deterministic instead of a property
# of whichever npm the runner happens to ship.
#
# The floor is per-file rather than per-step on purpose: these workflows
# set Node up only in order to install those tools, so every
# `node-version` in them is subject to it, and a newly added step that
# reintroduces 20 reds here rather than waiting for a triage run.
#
# The file list is explicit rather than derived from a grep for the
# install lines, so adding a workflow that installs floored tooling is a
# deliberate edit here rather than something a grep silently picks up or
# silently misses. ci-release-job.bats asserted the ci.yml half
# separately until #847; that assertion now lives here, because two
# copies of one invariant drift — this suite already had the matching
# prose corrected in one copy and missed in the other once. The build
# side carries the remaining instance, as NODE_MIN_VERSION in
# scripts/setup/dependencies.sh.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
WORKFLOW_DIR="${SCRIPT_DIR}/../.github/workflows"

# The highest of the engine floors declared by the tools these workflows
# install, as a major. asar's real floor is 22.12.0, but setup-node
# resolves "22" to the latest 22.x — well past 22.12 — so a major
# comparison is the honest granularity here.
readonly NODE_MIN_MAJOR=22

readonly FLOORED_WORKFLOWS=(
	ci.yml
	issue-triage-v2.yml
)

# The `node-version` majors declared in workflow <1>, comment lines
# skipped so a commented-out key cannot stand in for a live one.
#
# `grep -oE` cannot return a capture group, so matching the key and
# extracting its major would take two passes; `[[ =~ ]]` captures the
# major directly into BASH_REMATCH.
node_majors() {
	local line re='node-version:[[:space:]]*"?([0-9]+)'
	while IFS= read -r line; do
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		[[ "$line" =~ $re ]] || continue
		printf '%s\n' "${BASH_REMATCH[1]}"
	done < "${WORKFLOW_DIR}/$1"
}

# The live `actions/setup-node` steps in workflow <1>, one per line and
# comment lines skipped so a commented-out step cannot inflate the count.
# Emitted rather than counted so the caller counts both sides of the
# comparison below the same way.
setup_node_steps() {
	local line
	while IFS= read -r line; do
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		[[ "$line" == *uses:*actions/setup-node* ]] || continue
		printf '%s\n' "$line"
	done < "${WORKFLOW_DIR}/$1"
}

@test "every workflow subject to the floor sets a node version" {
	# Guards the test below: a file that vanished, was renamed, or
	# stopped declaring a version at all would otherwise pass it on
	# empty input.
	local workflow
	for workflow in "${FLOORED_WORKFLOWS[@]}"; do
		[[ -f "${WORKFLOW_DIR}/${workflow}" ]]
		[[ -n "$(node_majors "$workflow")" ]]
	done
}

@test "every node-version in those workflows clears the floor" {
	# Collected rather than asserted in place, so a failure names every
	# offending file and version instead of only the first.
	local workflow major violations=''
	for workflow in "${FLOORED_WORKFLOWS[@]}"; do
		while IFS= read -r major; do
			[[ "$major" -ge "$NODE_MIN_MAJOR" ]] && continue
			violations+="${workflow}: ${major}"$'\n'
		done < <(node_majors "$workflow")
	done

	[[ -z "$violations" ]] || {
		printf 'below the Node %s floor:\n%s' \
			"$NODE_MIN_MAJOR" "$violations" >&2
		false
	}
}

@test "every setup-node step declares its own node-version" {
	# The two tests above leave one hole between them: test 1 asks only
	# for at least one version per file, and test 2 judges only the
	# versions that are present. So deleting a single `node-version`
	# key from a file that has others passes both, and that step
	# silently takes the runner's default Node instead of ours.
	#
	# Today that default clears the floor (22.23.2 on ubuntu-latest),
	# which is exactly why it would go unnoticed until the day it does
	# not. Whether the runtime is ours or the runner's is the thing
	# this suite exists to pin, so the count is asserted rather than
	# the value.
	local workflow steps keys mismatches=''
	for workflow in "${FLOORED_WORKFLOWS[@]}"; do
		steps=$(setup_node_steps "$workflow" | wc -l)
		keys=$(node_majors "$workflow" | wc -l)
		[[ "$steps" -eq "$keys" ]] && continue
		mismatches+="${workflow}: ${steps} setup-node step(s),"
		mismatches+=" ${keys} node-version key(s)"$'\n'
	done

	[[ -z "$mismatches" ]] || {
		printf 'setup-node steps without a node-version:\n%s' \
			"$mismatches" >&2
		false
	}
}
