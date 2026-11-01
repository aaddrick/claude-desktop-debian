#!/usr/bin/env bash
#===============================================================================
# Patch-stage integration test against a real official .deb.
#
# The BATS suites pin each patch against fixtures copied from shipped
# bytes, which is fast and runs everywhere. This closes the gap those
# leave: fixtures can drift from the real bundle, and a fixture cannot
# tell you whether the *repacked asar* still parses. #666 shipped a
# Fedora SyntaxError from a bad anchor while every structural test stayed
# green, so this runs the actual patch stage over the actual archive and
# then parses every emitted file.
#
# Asserts, in order:
#   1. the patch stage exits 0 — which includes the orchestrator's
#      retirement tripwire: every active patch changed the pristine bundle
#   2. every JS file a patch changed parses (node --check). Untouched
#      files are upstream's bytes; they may need a newer Node than the
#      host's, so they are not ours to parse. A changed file this Node
#      cannot read fails as unverifiable: since 4.4212.0 the patched
#      chunk uses `await using`, so run on Node 24+ (Electron 44's)
#   3. each injected marker survives the repack
#   4. a second pass is a no-op per patch and leaves the asar
#      byte-identical
#
# (4) is not decoration: through 1.24012.11 the patches resolved a single
# main file handed to them, and the move to per-anchor resolution (#820)
# introduced a class of bug where a patch destroys the very anchor it
# resolves on, so the second run fails to find its file at all — before
# any idempotency guard can fire. Only a second pass catches that.
#
# Usage:
#   tests/test-patch-stage.sh                 # pinned version, amd64
#   tests/test-patch-stage.sh <dir>           # pre-extracted resources dir
#                                             # (holding app.asar +
#                                             #  app.asar.unpacked)
#
# Not wired into tests.yml: it downloads a ~170 MB archive. Run it before
# shipping a patch change, and on every upstream bump.
#===============================================================================

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=scripts/_common.sh
source "$project_root/scripts/_common.sh"
# shellcheck source=scripts/setup/official-deb.sh
source "$project_root/scripts/setup/official-deb.sh"

_fail_count=0

_check() {
	local label="$1"
	shift
	if "$@"; then
		echo "  [PASS] $label"
	else
		echo "  [FAIL] $label"
		_fail_count=$((_fail_count + 1))
	fi
}

# Fetch and unpack the pinned official .deb into $1/resources.
_stage_official() {
	local dest="$1"
	local url_base='https://downloads.claude.ai/claude-desktop/apt/stable'
	local deb="$dest/official.deb"

	mkdir -p "$dest" || return 1
	echo "Downloading official .deb $OFFICIAL_DEB_VERSION (amd64)..."
	if ! curl -fsSL -o "$deb" "$url_base/$OFFICIAL_DEB_POOL_AMD64"; then
		echo 'Download failed' >&2
		return 1
	fi
	if ! echo "$OFFICIAL_DEB_SHA256_AMD64  $deb" | sha256sum -c - \
		> /dev/null; then
		echo 'SHA-256 mismatch on the official .deb' >&2
		return 1
	fi

	# _extract_deb_member handles the zst/xz/gz variance upstream has
	# shipped over time, so the member name is never hardcoded here.
	_extract_deb_member "$deb" 'data' "$dest" || return 1

	mkdir -p "$dest/resources"
	cp "$dest/usr/lib/claude-desktop/resources/app.asar" \
		"$dest/resources/" || return 1
	cp -a "$dest/usr/lib/claude-desktop/resources/app.asar.unpacked" \
		"$dest/resources/" || return 1
}

# Source every patch script, the way build.sh does. A glob, not a list:
# a hardcoded list here missed cowork-firmware-probe.sh when #947 wired
# it into the build, and every run since died on "command not found"
# before reaching a single real check.
_source_patch_stage() {
	local patch_sh
	for patch_sh in "$project_root"/scripts/patches/*.sh; do
		# shellcheck source=/dev/null
		source "$patch_sh"
	done
}

# Parse every JS file under $2 (patched tree) that differs from $1
# (pristine tree), and only those.
#
# Unchanged files are upstream's own bytes and parse under the Electron
# that ships them, whatever this host's Node makes of them. Since
# 4.4212.0 upstream ships `await using` (31 of 519 files), which Node 22
# cannot parse and Electron 44's bundled Node 24 can, so checking every
# file failed on clean upstream bytes. A changed file whose pristine
# copy also fails here is unverifiable on this Node — that fails too,
# so an old host can never pass a patch it could not read.
_parse_check_changed() {
	local pristine="$1" patched="$2"
	local f rel changed=0 broken=0 unverifiable=0
	while IFS= read -r f; do
		rel=${f#"$patched"/}
		cmp -s "$f" "$pristine/$rel" && continue
		changed=$((changed + 1))
		node --check "$f" > /dev/null 2>&1 && continue
		if [[ -f $pristine/$rel ]] \
			&& ! node --check "$pristine/$rel" > /dev/null 2>&1; then
			unverifiable=$((unverifiable + 1))
			echo "  unverifiable on Node $(node --version): $rel"
		else
			broken=$((broken + 1))
			echo "  SyntaxError in $rel"
		fi
	done < <(find "$patched/.vite/build" -name '*.js' -type f)
	echo "  parsed $changed patched JS file(s)"
	_check 'at least one patched JS file' test "$changed" -gt 0
	_check 'patched JS files parse' test "$broken" -eq 0
	_check 'host Node can parse what it checks' \
		test "$unverifiable" -eq 0
	if (( unverifiable > 0 )); then
		echo '  Rerun with a Node at least as new as the one bundled' \
			'in the shipped Electron (on PATH).'
	fi
}

main() {
	local src="${1:-}"
	local tmp
	tmp=$(mktemp -d) || exit 1
	# shellcheck disable=SC2064  # $tmp must expand now, not at trap time
	trap "rm -rf '$tmp'" EXIT

	# Globals the patch stage reads.
	work_dir="$tmp/work"
	app_staging_dir="$tmp/staging"
	mkdir -p "$work_dir" "$app_staging_dir/resources"
	# @electron/asar@3 (not @4): this harness reads and repacks an
	# asar, which every major does identically, and 3 is the last one
	# that runs on the Node 20 stable distros ship — so a pre-ship
	# patch check still runs on the host where #839 was reported.
	_resolve_asar "$work_dir" 3 || exit 1
	export work_dir app_staging_dir project_root asar_exec

	if [[ -n $src ]]; then
		cp "$src/app.asar" "$app_staging_dir/resources/" || exit 1
		cp -a "$src/app.asar.unpacked" "$app_staging_dir/resources/" \
			|| exit 1
	else
		_stage_official "$tmp/official" || exit 1
		cp "$tmp/official/resources/app.asar" \
			"$app_staging_dir/resources/" || exit 1
		cp -a "$tmp/official/resources/app.asar.unpacked" \
			"$app_staging_dir/resources/" || exit 1
	fi

	_source_patch_stage

	# Keep the pristine tree: the parse check compares against it.
	"$asar_exec" extract "$app_staging_dir/resources/app.asar" \
		"$tmp/pristine" > /dev/null || exit 1

	# --- pass 1 ----------------------------------------------------------
	echo '=== pass 1: patch stage ==='
	# Subshell: patch_app_asar exits on failure, which would take this
	# harness with it and skip every remaining assertion.
	( patch_app_asar ) > "$tmp/pass1.log" 2>&1
	local rc1=$?
	sed 's/^/  | /' "$tmp/pass1.log"
	_check 'patch stage exits 0' test "$rc1" -eq 0

	# --- every file a patch changed must parse ---------------------------
	echo '=== parse check ==='
	"$asar_exec" extract "$app_staging_dir/resources/app.asar" \
		"$tmp/verify" > /dev/null || exit 1
	_parse_check_changed "$tmp/pristine" "$tmp/verify"

	# --- injected markers must survive the repack -------------------------
	echo '=== marker check ==='
	local marker
	for marker in '/*cowork-bwrap-spawn*/' '/*cowork-bwrap-dl*/' \
		'CLAUDE_TRAY_USE_DARK_ICON' '/etc/claude/org-plugins' \
		'XDG_CURRENT_DESKTOP'; do
		_check "marker present: $marker" \
			grep -rqF -- "$marker" "$tmp/verify/.vite/build"
	done

	# --- pass 2: idempotency ----------------------------------------------
	echo '=== pass 2: idempotency ==='
	local before after
	before=$(sha256sum "$app_staging_dir/resources/app.asar" | cut -d' ' -f1)
	# PATCH_STAGE_RERUN flips the orchestrator's per-patch effect check:
	# pass 1 already required every patch to change the pristine bundle,
	# and here each one must leave the patched bundle alone, so a guard
	# that misses its own output is named rather than just a hash diff.
	( PATCH_STAGE_RERUN=1 patch_app_asar ) > "$tmp/pass2.log" 2>&1
	local rc2=$?
	sed 's/^/  | /' "$tmp/pass2.log"
	after=$(sha256sum "$app_staging_dir/resources/app.asar" | cut -d' ' -f1)
	_check 'second pass exits 0' test "$rc2" -eq 0
	_check 'asar byte-identical after re-run' test "$before" = "$after"

	echo
	if (( _fail_count > 0 )); then
		echo "FAILED: $_fail_count check(s)"
		return 1
	fi
	echo 'All patch-stage checks passed'
}

# Guarded so tests/app-asar.bats can source this file and check
# _source_patch_stage without downloading a .deb.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
