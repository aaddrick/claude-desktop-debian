#!/usr/bin/env bash
#
# verify-patches.sh
#
# Static-greps a patched index.js for the patch markers defined in
# a TSV (defaults to scripts/cowork-patch-markers.tsv). Exits non-zero
# on any miss and names the missing markers in the output.
#
# Defends against silent half-patched asars (issue #559 D6, PR #555).
# Reusable for non-cowork patch sets — pass any TSV of the same shape
# via the second arg.
#
# Usage:
#     verify-patches.sh <path> [markers-tsv]
#
# <path> may be:
#   * a JavaScript file (the index.js itself)
#   * an .asar archive (extracted on the fly via npx @electron/asar)
#   * a directory containing app.asar.contents/.vite/build/index.js
#
# Exit codes:
#   0  — every marker present.
#   1  — usage error or input not found.
#   2  — one or more markers missing (named on stderr).
#

set -u
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_markers_tsv="$script_dir/cowork-patch-markers.tsv"
markers_tsv="$default_markers_tsv"

usage() {
	cat <<-EOF >&2
		Usage: $(basename "$0") <path> [markers-tsv]

		<path> may be a .js file, an .asar archive, or a directory
		containing app.asar.contents/.vite/build/index.js. The script
		greps for patch markers (default: cowork, PR #555 / issue #559
		D6) and exits non-zero if any are missing.

		[markers-tsv] overrides the default TSV so the same script can
		verify other patch sets.
	EOF
}

# Parse the marker TSV into three parallel arrays. Skips comments
# and blank lines. Used by both the verify path here and by the
# BATS test, which sources this script (see _is_sourced below) to
# share parsing and avoid drift between the two consumers.
load_markers() {
	marker_names=()
	marker_patterns=()
	marker_samples=()

	if [[ ! -f $markers_tsv ]]; then
		echo "verify-patches: marker file not found:" \
			"$markers_tsv" >&2
		return 1
	fi

	local name pattern sample
	while IFS=$'\t' read -r name pattern sample; do
		[[ -z $name || $name == '#'* ]] && continue
		if [[ -z ${pattern:-} || -z ${sample:-} ]]; then
			echo "verify-patches: malformed row '$name'" \
				'in markers file' >&2
			return 1
		fi
		marker_names+=("$name")
		marker_patterns+=("$pattern")
		marker_samples+=("$sample")
	done < "$markers_tsv"

	if [[ ${#marker_names[@]} -eq 0 ]]; then
		echo 'verify-patches: no markers loaded' >&2
		return 1
	fi
}

# Resolve the input path to an actual index.js. For .asar inputs,
# extracts to a temp dir and echoes the inner index.js path. The
# caller cleans up via cleanup_tmp.
tmp_extract_dir=''
cleanup_tmp() {
	if [[ -n $tmp_extract_dir && -d $tmp_extract_dir ]]; then
		rm -rf "$tmp_extract_dir"
	fi
}
trap cleanup_tmp EXIT

resolve_index_js() {
	local input="$1"

	if [[ ! -e $input ]]; then
		echo "verify-patches: not found: $input" >&2
		return 1
	fi

	if [[ -d $input ]]; then
		local candidate="$input/app.asar.contents/.vite/build/index.js"
		if [[ -f $candidate ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
		echo "verify-patches: directory does not contain" \
			"app.asar.contents/.vite/build/index.js: $input" >&2
		return 1
	fi

	if [[ $input == *.asar ]]; then
		if ! command -v npx > /dev/null 2>&1; then
			echo 'verify-patches: npx not found; install Node.js' \
				'or pre-extract the asar' >&2
			return 1
		fi
		tmp_extract_dir="$(mktemp -d)"
		if ! npx --yes @electron/asar extract "$input" \
			"$tmp_extract_dir" > /dev/null 2>&1; then
			echo "verify-patches: asar extraction failed:" \
				"$input" >&2
			return 1
		fi
		local extracted="$tmp_extract_dir/.vite/build/index.js"
		if [[ ! -f $extracted ]]; then
			echo 'verify-patches: extracted asar lacks' \
				'.vite/build/index.js' >&2
			return 1
		fi
		printf '%s\n' "$extracted"
		return 0
	fi

	# Treat as a JS file (.js or any other extension) — let grep
	# decide whether the contents are sensible.
	printf '%s\n' "$input"
}

main() {
	if [[ $# -lt 1 || $# -gt 2 ]]; then
		usage
		return 1
	fi

	case "$1" in
		-h | --help)
			usage
			return 0
			;;
	esac

	if [[ $# -eq 2 ]]; then
		markers_tsv="$2"
	fi

	local index_js
	if ! index_js="$(resolve_index_js "$1")"; then
		return 1
	fi

	if ! load_markers; then
		return 1
	fi

	echo "Verifying patch markers in: $index_js"
	echo "Marker source: $markers_tsv"

	local i missing_names=()
	for i in "${!marker_names[@]}"; do
		if grep -qP -- "${marker_patterns[$i]}" "$index_js"; then
			printf '  OK   %s\n' "${marker_names[$i]}"
		else
			printf '  MISS %s\n' "${marker_names[$i]}" >&2
			missing_names+=("${marker_names[$i]}")
		fi
	done

	if [[ ${#missing_names[@]} -gt 0 ]]; then
		local joined
		joined="$(IFS=','; printf '%s' "${missing_names[*]}")"
		printf '\nverify-patches: %d/%d markers missing: %s\n' \
			"${#missing_names[@]}" "${#marker_names[@]}" "$joined" >&2
		return 2
	fi

	printf '\nAll %d patch markers present.\n' \
		"${#marker_names[@]}"
	return 0
}

# Library mode: when sourced (BATS test), expose load_markers and
# the markers_tsv path without running main.
_is_sourced() {
	[[ ${BASH_SOURCE[0]} != "${0}" ]]
}

if ! _is_sourced; then
	main "$@"
fi
