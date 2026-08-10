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
#   1. the patch stage exits 0
#   2. every JS file in the repacked asar parses (node --check)
#   3. each injected marker survives the repack
#   4. a second pass is a no-op and leaves the asar byte-identical
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

main() {
	local src="${1:-}"
	local tmp
	tmp=$(mktemp -d) || exit 1
	# shellcheck disable=SC2064  # $tmp must expand now, not at trap time
	trap "rm -rf '$tmp'" EXIT

	# Globals the patch stage reads.
	work_dir="$tmp/work"
	app_staging_dir="$tmp/staging"
	asar_exec=$(command -v asar || command -v npx)
	export work_dir app_staging_dir project_root asar_exec
	mkdir -p "$work_dir" "$app_staging_dir/resources"

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

	local patch_sh
	for patch_sh in quick-window org-plugins virtiofsd-probe \
		cowork-bwrap tray-icon-selection; do
		# shellcheck source=/dev/null
		source "$project_root/scripts/patches/$patch_sh.sh"
	done
	# shellcheck source=scripts/patches/app-asar.sh
	source "$project_root/scripts/patches/app-asar.sh"

	# --- pass 1 ----------------------------------------------------------
	echo '=== pass 1: patch stage ==='
	# Subshell: patch_app_asar exits on failure, which would take this
	# harness with it and skip every remaining assertion.
	( patch_app_asar ) > "$tmp/pass1.log" 2>&1
	local rc1=$?
	sed 's/^/  | /' "$tmp/pass1.log"
	_check 'patch stage exits 0' test "$rc1" -eq 0

	# --- every emitted file must parse ------------------------------------
	echo '=== parse check ==='
	"$asar_exec" extract "$app_staging_dir/resources/app.asar" \
		"$tmp/verify" > /dev/null || exit 1
	local broken=0 total=0 f
	while IFS= read -r f; do
		total=$((total + 1))
		if ! node --check "$f" > /dev/null 2>&1; then
			broken=$((broken + 1))
			echo "  SyntaxError in ${f#"$tmp"/verify/}"
		fi
	done < <(find "$tmp/verify/.vite/build" -name '*.js' -type f)
	echo "  parsed $total JS files"
	_check "all $total JS files parse" test "$broken" -eq 0

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
	( patch_app_asar ) > "$tmp/pass2.log" 2>&1
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

main "$@"
