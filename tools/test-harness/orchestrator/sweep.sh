#!/usr/bin/env bash
# sweep.sh — run a test sweep for a row.
#
# Usage:
#   ROW=KDE-W ./orchestrator/sweep.sh
#   CLAUDE_DESKTOP_LAUNCHER=/usr/bin/claude-desktop ROW=KDE-W ./orchestrator/sweep.sh
#
# Output bundle layout:
#   results/results-${ROW}-${DATE}/
#     ├── junit.xml
#     ├── html/                   (Playwright HTML report)
#     └── test-output/            (per-test attachments)

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
harness_dir="$(dirname "$script_dir")"
readonly harness_dir

readonly row="${ROW:-KDE-W}"
date_str="$(date -u +%Y%m%dT%H%M%SZ)"
readonly date_str
readonly bundle_id="results-${row}-${date_str}"
readonly results_root="${OUTPUT_DIR:-${harness_dir}/results}"
readonly bundle_dir="${results_root}/${bundle_id}"

mkdir -p "$bundle_dir"

cd "$harness_dir" || exit 1

# Backend banner. CLAUDE_HARNESS_USE_WAYLAND=1 flips every runner from
# the default X11/XWayland backend to native Wayland — see the
# "Environment variables" table in tools/test-harness/README.md.
if [[ "${CLAUDE_HARNESS_USE_WAYLAND:-}" == '1' ]]; then
	printf 'sweep: native Wayland backend (CLAUDE_HARNESS_USE_WAYLAND=1)\n' >&2
fi

# Fast-fail prereq checks — only matter when the sweep includes
# Quick Entry runners (S31, future S29/S30/S32/S34/S35/S37 +
# T06 / QE-* additions). Skip with QE_PREREQ_CHECK=0 if running
# a sweep that excludes those.
if [[ "${QE_PREREQ_CHECK:-1}" == "1" ]]; then
	if ! command -v ydotool >/dev/null 2>&1; then
		printf 'sweep: ydotool not on PATH — Quick Entry runners will skip.\n' >&2
		printf '  install: dnf install ydotool / apt install ydotool\n' >&2
		printf '  to suppress this check: QE_PREREQ_CHECK=0\n' >&2
	fi
	socket="${YDOTOOL_SOCKET:-/tmp/.ydotool_socket}"
	if [[ ! -S "$socket" ]]; then
		printf 'sweep: ydotoold socket missing at %s — daemon not running.\n' \
			"$socket" >&2
		printf '  start: sudo systemctl start ydotool.service\n' >&2
		printf '  see tools/test-harness/README.md "Quick Entry runners" for one-time setup\n' >&2
	fi
fi

ROW="$row" \
RESULTS_DIR="$bundle_dir" \
	npx playwright test
rc=$?

# Bundle into tar.zst for orchestrator pickup. Best-effort — keep the
# uncompressed dir even if zstd is unavailable.
if command -v zstd >/dev/null 2>&1; then
	tar --zstd -cf "${results_root}/${bundle_id}.tar.zst" \
		-C "$results_root" "$bundle_id" 2>/dev/null \
		&& printf 'bundle: %s/%s.tar.zst\n' "$results_root" "$bundle_id"
fi

printf 'row=%s exit=%d dir=%s\n' "$row" "$rc" "$bundle_dir"

# Quick summary if junit.xml landed. Prefer Node so we sum across all
# <testsuite> elements (grep+head only saw the first suite, undercounting
# multi-suite reports). Fall back to the legacy grep path when node isn't
# on PATH so the harness stays usable on minimal images.
if [[ -f "${bundle_dir}/junit.xml" ]]; then
	if command -v node >/dev/null 2>&1; then
		read -r tests failures errors skipped \
			< <(node -e "$(cat <<'EOF'
const fs = require('fs');
const xml = fs.readFileSync(process.argv[1], 'utf8');
const sumAttr = (a) => Array.from(
	xml.matchAll(new RegExp(`<testsuite[^>]*\\b${a}="(\\d+)"`, 'g'))
).reduce((s, m) => s + parseInt(m[1], 10), 0);
console.log([
	sumAttr('tests'), sumAttr('failures'),
	sumAttr('errors'), sumAttr('skipped'),
].join(' '));
EOF
)" "${bundle_dir}/junit.xml")
		printf 'summary: tests=%s failures=%s errors=%s skipped=%s\n' \
			"$tests" "$failures" "$errors" "$skipped"
	elif command -v grep >/dev/null 2>&1; then
		tests="$(grep -oP 'tests="\K\d+' "${bundle_dir}/junit.xml" \
			| head -1 || printf '?')"
		failures="$(grep -oP 'failures="\K\d+' "${bundle_dir}/junit.xml" \
			| head -1 || printf '?')"
		errors="$(grep -oP 'errors="\K\d+' "${bundle_dir}/junit.xml" \
			| head -1 || printf '?')"
		skipped="$(grep -oP 'skipped="\K\d+' "${bundle_dir}/junit.xml" \
			| head -1 || printf '?')"
		printf 'summary: tests=%s failures=%s errors=%s skipped=%s\n' \
			"$tests" "$failures" "$errors" "$skipped"
	fi
fi

exit "$rc"
