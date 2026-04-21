#!/usr/bin/env bash
# Stage 2 suspicious-input scan for issue triage v2.
#
# Reads the raw issue body + title from a JSON file and scans for
# prompt-injection tells listed in
# taxonomies/suspicious-input-tells.json. Any match routes the issue
# to 8b human-deferral with reason `suspicious-input — manual review`,
# bypassing the LLM classifier entirely. The scanner is conservative
# by design — the structured defenses downstream (wrap-as-data, fresh
# reviewer context, schema-constrained output) remain the actual
# mitigation; Stage 2 is the front-line tripwire.
#
# Usage: suspicious-input-scan.sh <issue.json> <tells.json> <output.json>
#
# Reads `.title` and `.body` from <issue.json>, each tell's `pattern`
# from <tells.json>, writes
#   { "suspicious": <bool>, "matched_tells": [<id>, ...] }
# to <output.json>.
#
# Patterns are PCRE (grep -P); case-insensitive; multi-line DOTALL
# where the pattern spans lines (grep -z handles the body as one
# blob). Empty body or title scanning is a no-op — the scan ignores
# absent fields rather than treating them as matches.

set -o errexit
set -o nounset
set -o pipefail

issue_json="${1:?issue.json required}"
tells_json="${2:?tells.json required}"
output="${3:?output path required}"

# ─── Read fields ──────────────────────────────────────────────────
# `// ""` turns a JSON null into an empty string. `-r` strips the
# quotes so a legitimately-empty field is "" rather than the literal
# four-char string "null".

title=$(jq -r '.title // ""' "${issue_json}")
body=$(jq -r '.body // ""' "${issue_json}")

# ─── Scan ─────────────────────────────────────────────────────────
# Each tell's regex runs against the concatenated title + body. Using
# printf '%s\n%s' keeps them on separate lines so patterns that
# require line-anchored match (none do today) stay line-aware.
#
# grep -P is PCRE for `\x{...}` unicode escapes. -i is case-
# insensitive for verbal tells. -z treats the input as one record
# separated by NUL so patterns can span lines (relevant for the
# long-base64-block tell).

combined=$(printf '%s\n%s' "${title}" "${body}")

matched='[]'

while IFS= read -r tell; do
	tell_id=$(jq -r '.id' <<<"${tell}")
	pattern=$(jq -r '.pattern' <<<"${tell}")

	# grep -zP reads the whole input as one record so patterns can
	# span lines; -q because we only need the exit status. `if`
	# consumes grep's exit code, so the non-match exit 1 doesn't trip
	# pipefail + errexit.
	if printf '%s' "${combined}" \
			| grep -qziP -- "${pattern}" 2>/dev/null; then
		matched=$(jq --arg id "${tell_id}" \
			'. + [$id]' <<<"${matched}")
	fi
done < <(jq -c '.tells[]' "${tells_json}")

# ─── Output ───────────────────────────────────────────────────────

suspicious=$(jq 'length > 0' <<<"${matched}")

jq -n \
	--argjson suspicious "${suspicious}" \
	--argjson matched "${matched}" \
	'{
		suspicious: $suspicious,
		matched_tells: $matched
	}' > "${output}"
