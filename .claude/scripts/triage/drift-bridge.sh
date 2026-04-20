#!/usr/bin/env bash
# Drift-bridge sweep for issue triage v2.
#
# When Stage 3 detects version drift (claimed_version !=
# CLAUDE_DESKTOP_VERSION), Stage 7 runs this sweep BEFORE forcing a
# deferral. Turns a bare "bot saw drift, gave up" into a useful "these
# commits / PRs in the drift window may already address your
# symptom — please verify."
#
# Usage: drift-bridge.sh <investigation_json> <claimed_version> \
#                        <gh_repo> <output_json>
#
# Approach: resolve claimed_version to an approximate date by grep-ing
# git log for the version string (CI commits typically mention the
# version when bumping URLs). Fall back to today - 60 days if no
# match. Then run two cheap, bounded searches:
#   (1) git log since that date, touching files named in investigation
#   (2) gh pr list --state merged with basename match + merged:>date
#
# Output is a JSON object with `commits` and `prs` arrays; the Stage
# 8b renderer formats each as a bullet. Empty arrays simply skip the
# drift-bridge-candidates block in the comment.

set -o errexit
set -o nounset
set -o pipefail

investigation="${1:?investigation.json required}"
claimed_version="${2:?claimed_version required}"
gh_repo="${3:?gh repo required}"
output="${4:?output path required}"

# ─── Resolve claimed_version → approximate date ──────────────────
# The project's CI bumps URLs in scripts/setup/detect-host.sh and
# nix/claude-desktop.nix when CLAUDE_DESKTOP_VERSION is updated. Those
# commits mention the new version string. First-match commit date
# approximates when that version became current in this repo.

anchor_date=""
if [[ -n "${claimed_version}" && "${claimed_version}" != "null" ]]; then
	anchor_date=$(git log --all \
		--grep="${claimed_version}" \
		--pretty=format:'%cI' \
		2>/dev/null \
		| tail -1 || true)
fi

if [[ -z "${anchor_date}" ]]; then
	# Fallback: 60 days ago.
	anchor_date=$(date -u -d '60 days ago' '+%Y-%m-%dT%H:%M:%SZ')
fi

# ─── Collect files named in findings ──────────────────────────────
# Repo-local paths only. reference-source/ paths are beautified
# upstream JS — git history doesn't track them, so they can't bridge.

mapfile -t repo_files < <(jq -r \
	'.findings[]?.file | select(startswith("reference-source/") | not)' \
	"${investigation}" | sort -u)

# ─── git log sweep ────────────────────────────────────────────────

commits_json='[]'

if [[ ${#repo_files[@]} -gt 0 ]]; then
	# git log on specific files. Output NUL-delimited fields.
	while IFS=$'\x1f' read -r sha subject date; do
		[[ -z "${sha}" ]] && continue
		entry=$(jq -n \
			--arg sha "${sha}" \
			--arg subject "${subject}" \
			--arg date "${date}" \
			'{sha: $sha, subject: $subject, date: $date}')
		commits_json=$(jq --argjson c "${entry}" \
			'. + [$c]' <<<"${commits_json}")
	done < <(git log \
		--since="${anchor_date}" \
		--pretty=format:'%H%x1f%s%x1f%cI' \
		-- "${repo_files[@]}" 2>/dev/null \
		| head -10 || true)
fi

# ─── gh pr list sweep ─────────────────────────────────────────────
# Search merged PRs whose title or body references the file basenames
# from findings, within the drift window.

prs_json='[]'

for f in "${repo_files[@]}"; do
	base=$(basename "${f}")
	# Bare basename searches often match too broadly; use the basename
	# with extension stripped only if it's a script/config (stable ID).
	search_term="${base}"

	while IFS= read -r pr; do
		[[ -z "${pr}" ]] && continue
		prs_json=$(jq --argjson p "${pr}" \
			'if any(.; .number == $p.number) then . else . + [$p] end' \
			<<<"${prs_json}")
	done < <(gh pr list \
		--repo "${gh_repo}" \
		--state merged \
		--search "${search_term} merged:>${anchor_date}" \
		--limit 5 \
		--json number,title,mergedAt 2>/dev/null \
		| jq -c '.[] | {number, title, mergedAt}' || true)
done

# ─── Assemble ─────────────────────────────────────────────────────

jq -n \
	--arg anchor_date "${anchor_date}" \
	--arg claimed_version "${claimed_version}" \
	--argjson commits "${commits_json}" \
	--argjson prs "${prs_json}" \
	'{
		claimed_version: $claimed_version,
		anchor_date: $anchor_date,
		commits: $commits,
		prs: $prs
	}' > "${output}"
