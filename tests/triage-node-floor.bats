#!/usr/bin/env bats
#
# triage-node-floor.bats
# The triage workflows set up a Node that can actually run the tools
# they install.
#
# Both issue-triage.yml and issue-triage-v2.yml `npm install -g` tools
# with a Node engine floor above 20: @electron/asar has declared
# engines.node >=22.12.0 since 4.0.0 and every 4.x release refuses to
# start below it, and @anthropic-ai/claude-code declares >=22.0.0.
#
# npm reports either mismatch as an EBADENGINE *warning*, not an error,
# so a too-old runtime installs the wrapper cleanly and leaves a binary
# that exists and never runs. Nothing fails at install time, and the
# failure surfaces later as a command that dies on first invocation —
# which is why this is asserted at the setup step rather than left to a
# `command -v` guard, which such a binary passes.
#
# The floor is per-file rather than per-step on purpose: these workflows
# set Node up only in order to install those tools, so every
# `node-version` in them is subject to it, and a newly added step that
# reintroduces 20 reds here rather than waiting for a triage run.
#
# The file list is explicit rather than derived from a grep for the
# install lines, because ci.yml installs the same tools and carries its
# own floor assertion in ci-release-job.bats. Same defect class in all
# three, plus the build side's NODE_MIN_VERSION in
# scripts/setup/dependencies.sh.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
WORKFLOW_DIR="${SCRIPT_DIR}/../.github/workflows"

# The highest of the engine floors declared by the tools these workflows
# install, as a major. asar's real floor is 22.12.0, but setup-node
# resolves "22" to the latest 22.x — well past 22.12 — so a major
# comparison is the honest granularity here.
readonly NODE_MIN_MAJOR=22

readonly FLOORED_WORKFLOWS=(
	issue-triage.yml
	issue-triage-v2.yml
)

# The `node-version` majors declared in workflow <1>, comments stripped
# so a commented-out key cannot stand in for a live one.
node_majors() {
	grep -vE '^[[:space:]]*#' "${WORKFLOW_DIR}/$1" \
		| grep -oE 'node-version:[[:space:]]*"?[0-9]+' \
		| grep -oE '[0-9]+$'
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
		echo "below the Node ${NODE_MIN_MAJOR} floor:" >&2
		echo "$violations" >&2
		false
	}
}
