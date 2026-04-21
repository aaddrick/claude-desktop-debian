#!/usr/bin/env bash
# Stage 5 mechanical validation for issue triage v2.
#
# Reads investigation.json (Stage 4 output), runs pure-bash checks
# against the repo + reference source + gh API, and emits
# validation.json with pass/fail per finding, per anchor, per
# pattern-sweep match, plus fetched bodies for related issues and
# duplicate_of target.
#
# Usage: validate.sh <investigation_json> <repo_root> <reference_root> \
#                    <gh_repo> <output_json>
#
# Phase 2 implementation — closed-world extraction for identifier
# claims uses a grep-based heuristic (±100 lines around the cited
# site, scanning for `case "xxx":` and object-literal keys). Phase 3
# may upgrade this to ast-grep for AST-level precision; the heuristic
# catches the canonical identifier-hallucination pattern in minified
# JavaScript (switch-on-string-literal) in Phase 2.

set -o errexit
set -o nounset
set -o pipefail

investigation="${1:?investigation.json required}"
repo_root="${2:?repo root required}"
reference_root="${3:?reference root required}"
gh_repo="${4:?gh repo required}"
output="${5:?output path required}"

# ─── Path resolution ──────────────────────────────────────────────
# Findings use paths relative to either the checkout root or the
# extracted reference tarball. `reference-source/` prefix routes to
# the tarball; everything else to the checkout.

resolve_path() {
	local f="$1"
	if [[ "${f}" == reference-source/* ]]; then
		printf '%s/%s' "${reference_root}" "${f#reference-source/}"
	else
		printf '%s/%s' "${repo_root}" "${f}"
	fi
}

# ─── Closed-world extraction ──────────────────────────────────────
# For identifier claims, extract the list of identifiers that appear
# as switch cases or object-literal keys within ±100 lines of the
# cited site. Passed to Stage 6 so the reviewer sees the bounded
# option list and can answer "is the claimed identifier in this
# list?" as a closed question.

closed_world_options() {
	local file="$1"
	local line="$2"

	[[ -f "${file}" ]] || return 0

	local start=$((line - 100))
	(( start < 1 )) && start=1
	local end=$((line + 100))

	# Union of: case "xxx":, case 'xxx':, object-literal keys (bare or
	# quoted). Sort unique. Output newline-delimited. `|| true` keeps
	# pipefail quiet when grep finds zero hits.
	sed -n "${start},${end}p" "${file}" \
		| grep -oP '(?:\bcase\s+["\x27]\K[^"\x27]+(?=["\x27])|(?:^|,|\{)\s*["\x27]?\K\w+(?=["\x27]?\s*:))' \
		| sort -u \
		|| true
}

# ─── Anchor grep ──────────────────────────────────────────────────
# Runs the proposed anchor regex against its target file. Match count
# must equal expected_match_count exactly (never ≥). For
# word-boundary-required anchors, the identifier portion is
# \b-wrapped by the investigation output already; we run grep -P
# straight.

anchor_match_count() {
	local target="$1"
	local regex="$2"

	[[ -f "${target}" ]] || { echo 0; return; }

	# grep -c exits 1 when count is 0 — it still prints "0" first, so
	# `|| true` just masks pipefail without doubling the output.
	grep -cP -- "${regex}" "${target}" 2>/dev/null || true
}

# ─── Schema-ban scan ──────────────────────────────────────────────
# Spec §4 lists phrases that invalidate the entire investigation
# output. The schema can't catch these (they're natural language);
# we scan for them here. A triggered ban drops the offending finding.

scan_bans() {
	local claim="$1"
	local -a bans=()

	if grep -qiE 'should stay as-is|should not change|is correct here|leave .*alone' \
			<<<"${claim}"; then
		bans+=("negative per-site assertion")
	fi
	if grep -qiE 'already fixed in #[0-9]+' <<<"${claim}" \
			&& ! grep -qiE '/(pull|commit|pr)/' <<<"${claim}"; then
		bans+=("'already fixed in #N' without diff/PR link")
	fi

	# printf with empty array still emits one blank line — guard it so
	# the caller's mapfile doesn't see a phantom empty element.
	if [[ ${#bans[@]} -gt 0 ]]; then
		printf '%s\n' "${bans[@]}"
	fi
}

# ─── Per-finding validation ───────────────────────────────────────

findings_out='[]'
findings_total=0
findings_passed=0

while IFS= read -r finding; do
	findings_total=$((findings_total + 1))

	file=$(jq -r '.file' <<<"${finding}")
	line_start=$(jq -r '.line_start' <<<"${finding}")
	line_end=$(jq -r '.line_end' <<<"${finding}")
	evidence=$(jq -r '.evidence_quote' <<<"${finding}")
	claim=$(jq -r '.claim' <<<"${finding}")
	claim_type=$(jq -r '.claim_type' <<<"${finding}")

	resolved=$(resolve_path "${file}")
	failure_reasons='[]'

	# Schema bans.
	mapfile -t ban_hits < <(scan_bans "${claim}")
	if [[ ${#ban_hits[@]} -gt 0 ]]; then
		for ban in "${ban_hits[@]}"; do
			failure_reasons=$(jq --arg r "schema ban: ${ban}" \
				'. + [$r]' <<<"${failure_reasons}")
		done
	fi

	# File existence + line range.
	file_exists=false
	line_in_range=false
	file_line_count=0
	if [[ -f "${resolved}" ]]; then
		file_exists=true
		file_line_count=$(wc -l < "${resolved}")
		if (( line_end <= file_line_count && line_start <= line_end )); then
			line_in_range=true
		else
			failure_reasons=$(jq \
				--arg r "line_end ${line_end} exceeds file length ${file_line_count}" \
				'. + [$r]' <<<"${failure_reasons}")
		fi
	else
		failure_reasons=$(jq --arg r "file not found: ${file}" \
			'. + [$r]' <<<"${failure_reasons}")
	fi

	# Evidence quote match at cited line.
	evidence_matched=false
	if [[ "${file_exists}" == "true" && "${line_in_range}" == "true" ]]; then
		range_start=$((line_start - 2))
		(( range_start < 1 )) && range_start=1
		range_end=$((line_end + 2))
		if sed -n "${range_start},${range_end}p" "${resolved}" \
				| grep -qF -- "${evidence}"; then
			evidence_matched=true
		else
			failure_reasons=$(jq \
				--arg r "evidence_quote not found at ${file}:${line_start}" \
				'. + [$r]' <<<"${failure_reasons}")
		fi
	fi

	# Closed-world options for identifier claims.
	cwo_json='null'
	if [[ "${claim_type}" == "identifier" && "${file_exists}" == "true" ]]; then
		mapfile -t cwo < <(closed_world_options "${resolved}" "${line_start}")
		cwo_json=$(printf '%s\n' "${cwo[@]}" | jq -R -s 'split("\n") | map(select(length>0))')
	fi

	# Overall pass/fail.
	passed=false
	if [[ "${file_exists}" == "true" \
			&& "${line_in_range}" == "true" \
			&& "${evidence_matched}" == "true" \
			&& "$(jq 'length' <<<"${failure_reasons}")" == "0" ]]; then
		passed=true
		findings_passed=$((findings_passed + 1))
	fi

	validated=$(jq -n \
		--argjson f "${finding}" \
		--argjson passed "${passed}" \
		--argjson file_exists "${file_exists}" \
		--argjson line_in_range "${line_in_range}" \
		--argjson evidence_matched "${evidence_matched}" \
		--argjson failure_reasons "${failure_reasons}" \
		--argjson cwo "${cwo_json}" \
		'{
			finding: $f,
			passed: $passed,
			file_exists: $file_exists,
			line_in_range: $line_in_range,
			evidence_quote_matched: $evidence_matched,
			closed_world_options: $cwo,
			failure_reasons: $failure_reasons
		}')

	findings_out=$(jq --argjson v "${validated}" '. + [$v]' <<<"${findings_out}")
done < <(jq -c '.findings[]?' "${investigation}")

# ─── Per-anchor validation ────────────────────────────────────────

anchors_out='[]'
anchors_total=0
anchors_passed=0

while IFS= read -r anchor; do
	anchors_total=$((anchors_total + 1))

	regex=$(jq -r '.regex' <<<"${anchor}")
	target=$(jq -r '.target_file' <<<"${anchor}")
	expected=$(jq -r '.expected_match_count' <<<"${anchor}")
	wb_required=$(jq -r '.word_boundary_required' <<<"${anchor}")

	resolved=$(resolve_path "${target}")
	failure_reasons='[]'

	actual=$(anchor_match_count "${resolved}" "${regex}")

	if [[ ! -f "${resolved}" ]]; then
		failure_reasons=$(jq --arg r "target_file not found: ${target}" \
			'. + [$r]' <<<"${failure_reasons}")
	elif [[ "${actual}" != "${expected}" ]]; then
		failure_reasons=$(jq \
			--arg r "match count ${actual} != expected ${expected}" \
			'. + [$r]' <<<"${failure_reasons}")
	fi

	# Substring check: if word_boundary_required, enforce that the regex
	# contains \b. Investigation prompts mandate it; this is the safety
	# net.
	if [[ "${wb_required}" == "true" ]] && ! grep -q '\\b' <<<"${regex}"; then
		failure_reasons=$(jq \
			--arg r "word_boundary_required=true but regex lacks \\b" \
			'. + [$r]' <<<"${failure_reasons}")
	fi

	passed=false
	if [[ "$(jq 'length' <<<"${failure_reasons}")" == "0" ]]; then
		passed=true
		anchors_passed=$((anchors_passed + 1))
	fi

	validated=$(jq -n \
		--argjson a "${anchor}" \
		--argjson passed "${passed}" \
		--argjson actual "${actual}" \
		--argjson failure_reasons "${failure_reasons}" \
		'{
			anchor: $a,
			passed: $passed,
			actual_match_count: $actual,
			failure_reasons: $failure_reasons
		}')

	anchors_out=$(jq --argjson v "${validated}" '. + [$v]' <<<"${anchors_out}")
done < <(jq -c '.proposed_anchors[]?' "${investigation}")

# ─── Related issues ───────────────────────────────────────────────
# Fetch the actual body of each cited issue. Stage 6 (Phase 3) rates
# exact/related/unrelated against this. For Phase 2 we archive the
# fetched body so the 8a prompt can include it.

related_out='[]'

while IFS= read -r ri; do
	num=$(jq -r '.number' <<<"${ri}")

	fetched=$(gh issue view "${num}" --repo "${gh_repo}" \
		--json title,state,body 2>/dev/null || echo '{}')

	title=$(jq -r '.title // ""' <<<"${fetched}")
	state=$(jq -r '.state // ""' <<<"${fetched}")
	body=$(jq -r '.body // ""' <<<"${fetched}")
	excerpt=$(printf '%s' "${body}" | head -c 500)
	fetch_ok=true
	if [[ -z "${title}" ]]; then
		fetch_ok=false
	fi

	entry=$(jq -n \
		--argjson ri "${ri}" \
		--arg title "${title}" \
		--arg state "${state}" \
		--arg excerpt "${excerpt}" \
		--argjson fetch_ok "${fetch_ok}" \
		'{
			related_issue: $ri,
			fetch_succeeded: $fetch_ok,
			fetched_title: $title,
			fetched_state: $state,
			body_excerpt: $excerpt
		}')

	related_out=$(jq --argjson v "${entry}" '. + [$v]' <<<"${related_out}")
done < <(jq -c '.related_issues[]?' "${investigation}")

# ─── Pattern sweep re-grep ────────────────────────────────────────
# Re-verify each claimed match site still contains the snippet.

sweeps_out='[]'

while IFS= read -r sweep; do
	claimed_count=$(jq -r '.match_count' <<<"${sweep}")

	verified=0
	while IFS= read -r match; do
		mfile=$(jq -r '.file' <<<"${match}")
		mline=$(jq -r '.line' <<<"${match}")
		msnippet=$(jq -r '.snippet' <<<"${match}")

		resolved=$(resolve_path "${mfile}")
		[[ -f "${resolved}" ]] || continue
		range_start=$((mline - 1))
		(( range_start < 1 )) && range_start=1
		range_end=$((mline + 1))

		if sed -n "${range_start},${range_end}p" "${resolved}" \
				| grep -qF -- "${msnippet}"; then
			verified=$((verified + 1))
		fi
	done < <(jq -c '.matches[]?' <<<"${sweep}")

	entry=$(jq -n \
		--argjson s "${sweep}" \
		--argjson verified "${verified}" \
		--argjson claimed "${claimed_count}" \
		'{
			sweep: $s,
			matches_verified: $verified,
			match_count_claimed: $claimed
		}')

	sweeps_out=$(jq --argjson v "${entry}" '. + [$v]' <<<"${sweeps_out}")
done < <(jq -c '.pattern_sweep[]?' "${investigation}")

# ─── Assemble output ──────────────────────────────────────────────

jq -n \
	--argjson findings "${findings_out}" \
	--argjson anchors "${anchors_out}" \
	--argjson related "${related_out}" \
	--argjson sweeps "${sweeps_out}" \
	--argjson findings_total "${findings_total}" \
	--argjson findings_passed "${findings_passed}" \
	--argjson anchors_total "${anchors_total}" \
	--argjson anchors_passed "${anchors_passed}" \
	'{
		findings: $findings,
		proposed_anchors: $anchors,
		related_issues: $related,
		pattern_sweep: $sweeps,
		summary: {
			findings_total: $findings_total,
			findings_passed: $findings_passed,
			anchors_total: $anchors_total,
			anchors_passed: $anchors_passed,
			related_issues_fetched: ($related | length)
		}
	}' > "${output}"
