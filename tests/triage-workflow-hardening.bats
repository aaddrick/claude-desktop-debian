#!/usr/bin/env bats
#
# triage-workflow-hardening.bats
# The triage workflow keeps the posture its own comments argue for.
#
# The triage jobs run with ANTHROPIC_API_KEY and `issues: write`, and
# the investigator stage is the one LLM call that mixes
# attacker-controlled issue text with tool access. Three properties
# follow from that:
#
#   1. the Claude CLI is version-pinned, not a floating `latest`
#   2. no call runs on --dangerously-skip-permissions
#   3. the checkout does not persist the job token into .git/config
#
# Each was argued for in `issue-triage-v2.yml`'s own comments and held
# in place by nothing else. That is how the deleted v1 workflow came to
# differ from production on all three at once while reading as
# deliberate (#867): a comment explaining a posture does not keep it.
#
# Asserted file-wide rather than at the sites that established it, so a
# newly added job inherits the requirement instead of bypassing it.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
WORKFLOW_DIR="${SCRIPT_DIR}/../.github/workflows"

readonly TRIAGE_WORKFLOWS=(
	issue-triage-v2.yml
)

# Workflow <1> with comment lines stripped, so a `#` line that merely
# names a flag cannot satisfy or violate an assertion. The workflow
# deliberately mentions --dangerously-skip-permissions in a comment
# explaining what it uses instead.
uncommented() {
	grep -vE '^[[:space:]]*#' "${WORKFLOW_DIR}/$1" || true
}

@test "the triage workflows are present and non-empty" {
	# Guards every test below: a renamed or vanished file would
	# otherwise pass them all on empty input.
	local workflow
	for workflow in "${TRIAGE_WORKFLOWS[@]}"; do
		[[ -s "${WORKFLOW_DIR}/${workflow}" ]]
		[[ -n "$(uncommented "$workflow")" ]]
	done
}

@test "every claude-code install is version-pinned" {
	# Matched on the package name alone rather than on
	# `npm install -g <pkg>`: `npm i -g` and `npm install --global` are
	# the same install, and keying on one spelling would pass the others
	# vacuously by finding no lines to judge.
	local workflow line offenders=''
	for workflow in "${TRIAGE_WORKFLOWS[@]}"; do
		while IFS= read -r line; do
			[[ "$line" == *"claude-code@"* ]] && continue
			line="${line#"${line%%[![:space:]]*}"}"
			offenders+="${workflow}: ${line}"$'\n'
		done < <(uncommented "$workflow" \
			| grep -F '@anthropic-ai/claude-code' || true)
	done

	[[ -z "$offenders" ]] || {
		printf 'unpinned claude-code install:\n%s' "$offenders" >&2
		false
	}
}

@test "no triage call runs on --dangerously-skip-permissions" {
	local workflow hits offenders=''
	for workflow in "${TRIAGE_WORKFLOWS[@]}"; do
		hits=$(uncommented "$workflow" \
			| grep -c -- '--dangerously-skip-permissions' || true)
		[[ "$hits" -eq 0 ]] && continue
		offenders+="${workflow}: ${hits} occurrence(s)"$'\n'
	done

	[[ -z "$offenders" ]] || {
		printf 'skip-permissions in a triage workflow:\n%s' \
			"$offenders" >&2
		false
	}
}

@test "every triage checkout sets persist-credentials: false" {
	# Counted rather than matched per step: the key must appear once per
	# checkout, so a newly added checkout without it reds here even
	# though the existing ones still carry theirs.
	local workflow checkouts optouts mismatches=''
	for workflow in "${TRIAGE_WORKFLOWS[@]}"; do
		checkouts=$(uncommented "$workflow" \
			| grep -c 'uses:[[:space:]]*actions/checkout@' || true)
		optouts=$(uncommented "$workflow" \
			| grep -c 'persist-credentials:[[:space:]]*false' \
			|| true)
		[[ "$checkouts" -eq "$optouts" ]] && continue
		mismatches+="${workflow}: ${checkouts} checkout(s),"
		mismatches+=" ${optouts} persist-credentials: false"$'\n'
	done

	[[ -z "$mismatches" ]] || {
		printf 'checkout persisting the job token:\n%s' \
			"$mismatches" >&2
		false
	}
}
