#!/usr/bin/env bats
#
# triage-classify-vocabulary.bats
# The classifier's label vocabulary comes from the repo, not from prose.
#
# `classify.txt` used to hand the model a list of "safe choices" that
# had drifted from the repo's actual labels — `format: aur`, `tray`,
# `nix` and `build` were all suggested and none of them existed (#867).
# The Stage 9 cached-set check caught every one, so the only symptom
# was a `::notice::Label 'build' not in repo label set` on a run nobody
# re-reads: a prompt degrading silently, per issue.
#
# The fix is to interpolate the cached `gh label list` output into the
# prompt instead, which removes the class. These tests hold that in
# place and cover the residue it cannot remove: the handful of label
# names the pipeline still hardcodes outside the injected block, each
# of which is a rename away from the same silent failure.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
WORKFLOW="${REPO_ROOT}/.github/workflows/issue-triage-v2.yml"
PROMPT="${REPO_ROOT}/.claude/scripts/prompts/classify.txt"
SCHEMA="${REPO_ROOT}/.claude/scripts/schemas/classify.json"

# The repo whose label set is the vocabulary. Not `github.repository`:
# see the live test below.
readonly CANONICAL_REPO='aaddrick/claude-desktop-debian'

# Label names the pipeline states by hand rather than reading from the
# injected block, with the site that states each:
#
#   priority: critical  prompt ("never emit"), Stage 9 (demoted to
#                       medium if the classifier emits it anyway)
#   priority: medium    Stage 9 default-fill for the priority slot
#   security            prompt criterion (exposure in what we ship, or
#                       in what runs with our credentials)
#   bug/enhancement/    Stage 9 class map, and the duplicate-target
#   documentation/      class-inheritance loop
#   question
#   triage: *           Stage 9 triage-state map
#
# A rename on any of these degrades the pipeline without erroring, so
# the live-set test below is what makes it fail loudly instead.
readonly PINNED_LABELS=(
	'priority: critical'
	'priority: medium'
	'security'
	'bug'
	'enhancement'
	'documentation'
	'question'
	'triage: investigated'
	'triage: duplicate'
	'triage: needs-info'
	'triage: not-actionable'
	'triage: needs-human'
)

# The `Classify issue` step's body, up to the next step. Scoped rather
# than matched file-wide: `repo-labels.json` also appears in Stage 9's
# apply_if_valid, which is the gate that made this bug invisible, and
# matching it there would pass the interpolation test vacuously.
classify_step() {
	awk '/^      - name: Classify issue$/ { f = 1; next }
	     f && /^      - name: / { exit }
	     f { print }' "${WORKFLOW}"
}

# True when label name <1> is one PINNED_LABELS already accounts for.
is_pinned() {
	local pinned
	for pinned in "${PINNED_LABELS[@]}"; do
		[[ "$1" == "$pinned" ]] && return 0
	done
	return 1
}

# Skip the calling test when `gh` cannot reach the API — except in CI,
# where a missing or unauthenticated `gh` would turn the live-set
# assertion into a silent no-op, so it fails there instead.
require_gh() {
	local reason
	if ! command -v gh >/dev/null 2>&1; then
		reason='gh not installed'
	elif ! gh auth status >/dev/null 2>&1; then
		reason='gh not authenticated'
	else
		return 0
	fi

	if [[ -n "${CI:-}" ]]; then
		echo "${reason} — cannot verify the live label set" >&2
		return 1
	fi
	skip "${reason}"
}

@test "the classify prompt, schema and workflow are all present" {
	# Guards every test below: a renamed or vanished file would
	# otherwise satisfy the negative assertions on empty input.
	[[ -s "${PROMPT}" ]]
	[[ -s "${SCHEMA}" ]]
	[[ -s "${WORKFLOW}" ]]
	[[ -n "$(classify_step)" ]]
}

@test "the classify step interpolates the cached repo label set" {
	local step
	step="$(classify_step)"
	[[ "$step" == *'/tmp/triage/repo-labels.json'* ]]
	[[ "$step" == *'<repo_labels'* ]]
}

@test "the label set is cached before the classify step reads it" {
	local cache_line classify_line
	cache_line=$(grep -n '^      - name: Cache repo label set$' \
		"${WORKFLOW}" | cut -d: -f1)
	classify_line=$(grep -n '^      - name: Classify issue$' \
		"${WORKFLOW}" | cut -d: -f1)
	[[ -n "$cache_line" ]]
	[[ -n "$classify_line" ]]
	[[ "$cache_line" -lt "$classify_line" ]]
}

@test "an empty label set stops the run instead of stripping the vocabulary" {
	# jq on an empty array yields an empty string, which would
	# otherwise produce an empty <repo_labels> block and a classifier
	# told its whole vocabulary is nothing.
	local step
	step="$(classify_step)"
	[[ "$step" == *'-z "${label_lines}"'* ]]
	[[ "$step" == *'repo label set empty'* ]]
}

@test "the prompt carries the security criterion" {
	# The rule this PR is transcribing (#867): exposure in what we ship,
	# or in what runs with our credentials. It lived only in an issue
	# comment, where the classifier could not reach it, and a prompt
	# paragraph is deletable in one keystroke with no other symptom.
	local section
	section=$(sed -n '/^- `suggested_labels`/,/^- `duplicate_of`/p' \
		"${PROMPT}")
	[[ -n "$section" ]]
	[[ "$section" == *'`security`'* ]]
	[[ "$section" == *'credentials'* ]]
}

@test "the prompt sends the model to the injected block for its vocabulary" {
	grep -qF '<repo_labels>' "${PROMPT}"
	grep -qF '<repo_labels>' "${SCHEMA}"
}

@test "the prompt and schema enumerate no namespaced labels of their own" {
	# The three namespaced families are what a hand-maintained list
	# reaches for first, and `format: aur` / `format: nix` vs `nix` is
	# exactly how the drift showed up. Anything found here that is not
	# pinned above is a list growing back.
	local found name offenders=''
	while IFS= read -r found; do
		name="${found//\`/}"
		is_pinned "$name" && continue
		offenders+="${name}"$'\n'
	done < <(grep -ohE '`(priority|format|platform): [a-z0-9|]+`' \
		"${PROMPT}" "${SCHEMA}" | sort -u)

	[[ -z "$offenders" ]] || {
		printf 'hardcoded label vocabulary in the prompt:\n%s' \
			"$offenders" >&2
		false
	}
}

@test "every pinned label name exists in the repo's live label set" {
	# The point sabiut made on #867: if a hardcoded name has to stay,
	# intersect it against `gh label list` so a rename fails loudly
	# rather than degrading a prompt. Same source as the Stage 9 gate.
	local labels name missing=''
	require_gh

	# Always the canonical repo, named explicitly. The vocabulary being
	# pinned is this project's, and the triage pipeline only ever runs
	# there; a bare `gh label list` takes GH_REPO or the git remote, and
	# on a contributor's fork that is the fork, whose label set is
	# GitHub's nine defaults — eight of the twelve names below missing
	# and every push to a fork branch red.
	labels=$(gh label list --repo "$CANONICAL_REPO" --limit 200 \
		--json name --jq '.[].name') || {
		echo 'gh label list failed' >&2
		false
	}
	[[ -n "$labels" ]]

	for name in "${PINNED_LABELS[@]}"; do
		grep -qxF "$name" <<<"$labels" && continue
		missing+="${name}"$'\n'
	done

	[[ -z "$missing" ]] || {
		printf 'pinned label missing from the repo label set:\n%s' \
			"$missing" >&2
		false
	}
}
