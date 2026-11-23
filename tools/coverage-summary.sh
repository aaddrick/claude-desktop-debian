#!/usr/bin/env bash
#
# coverage-summary.sh — render the Coverage workflow's reports as a
# Markdown table for $GITHUB_STEP_SUMMARY (#980).
#
# Usage: tools/coverage-summary.sh <coverage-dir>
#
# Reads kcov's merged JSON (<dir>/bats/kcov-merged/coverage.json) and
# c8's LCOV (<dir>/c8/lcov.info). Informational only: a missing or
# unreadable report becomes a "not produced" row, never a non-zero
# exit, so the summary step cannot fail the job.

cov_dir=${1:-coverage}

kcov_json="$cov_dir/bats/kcov-merged/coverage.json"
c8_lcov="$cov_dir/c8/lcov.info"

# kcov's JSON lists every file first and the run totals last, each
# under the same three keys, so the totals are the LAST match. Parsed
# without jq so the script runs on a bare runner.
kcov_field() {
	grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"?[0-9.]+" "$kcov_json" \
		| tail -n 1 | grep -oE '[0-9.]+$'
}

# Markdown code spans for the scope column, kept in double quotes so the
# backticks are literal text rather than command substitution.
bats_scope="\`scripts/\`, \`build.sh\`, \`tools/\`"
c8_scope="\`scripts/cowork-fallback/\`"

echo '## Line coverage (informational, no threshold)'
echo
echo '| Suite | Scope | Lines hit | Lines | Coverage |'
echo '|---|---|---:|---:|---:|'

if [[ -r $kcov_json ]]; then
	printf '| BATS (kcov) | %s | %s | %s | %s%% |\n' "$bats_scope" \
		"$(kcov_field covered_lines)" "$(kcov_field total_lines)" \
		"$(kcov_field percent_covered)"
else
	echo "| BATS (kcov) | $bats_scope | – | – | not produced |"
fi

if [[ -r $c8_lcov ]]; then
	awk -F: -v scope="$c8_scope" '
		/^LF:/ { total += $2 }
		/^LH:/ { hit += $2 }
		END {
			pct = total ? sprintf("%.1f", 100 * hit / total) : "0.0"
			printf "| protocol smoke (c8) | %s | %d | %d | %s%% |\n", scope, hit, total, pct
		}' "$c8_lcov"
else
	echo "| protocol smoke (c8) | $c8_scope | – | – | not produced |"
fi

echo
echo "Per-file reports are in the \`coverage\` artifact (Cobertura and JSON from kcov, LCOV from c8)."
