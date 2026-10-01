#!/usr/bin/env bash
#===============================================================================
# Patch-necessity audit against the official Claude Desktop for Linux .deb.
#
# Report-only: runs every legacy patch's detection anchor against the
# official bundle and prints a verdict matrix. Mutates nothing. Verdicts
# feed docs/learnings/official-deb-rebase-verification.md and decide which
# patches the v3.0.0 rebase deletes.
#
# Usage:
#   tools/patch-necessity-audit.sh                  # fetch pinned amd64
#   tools/patch-necessity-audit.sh --deb FILE       # audit a local .deb
#   tools/patch-necessity-audit.sh --tree DIR       # audit an extracted
#                                                   # data.tar root
#
# Verdicts:
#   not-needed  official bytes already contain the fix (or the construct
#               the patch targets does not exist)
#   needed?     the construct exists and the fix is absent — candidate
#               survivor, confirm behaviorally before keeping
#   check       ambiguous — needs a human read
#===============================================================================

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project_root=$(dirname "$script_dir")

# shellcheck source=scripts/_common.sh
source "$project_root/scripts/_common.sh"
# shellcheck source=scripts/setup/official-deb.sh
source "$project_root/scripts/setup/official-deb.sh"

architecture=$(dpkg --print-architecture 2>/dev/null || echo amd64)
tree_dir=''
local_deb_path=''

usage() {
	# Derive the header's extent rather than hardcoding a line range.
	# The old '2,20p' was correct when it was written and silently went
	# stale as the block grew: --help stopped mid-list and dropped the
	# `check` verdict, which is the most common one in the matrix.
	local close
	close=$(grep -n '^#====' "${BASH_SOURCE[0]}" | sed -n '2s/:.*//p')
	sed -n "2,$((close - 1))p" "${BASH_SOURCE[0]}"
	exit "${1:-0}"
}

cleanup() {
	[[ -n ${work_dir:-} ]] && rm -rf "$work_dir"
}

# Parse argv, fetch or accept a tree, and stage it for the probes.
# Sets: work_dir, tree_dir, app_dir, build_dir, main_view_js
_stage_tree() {
	while (( $# )); do
		case "$1" in
			--deb)	local_deb_path="$2"; shift 2 ;;
			--tree)	tree_dir="$2"; shift 2 ;;
			-h|--help)	usage ;;
			*)	echo "Unknown argument: $1" >&2; usage 1 ;;
		esac
	done

	work_dir=$(mktemp -d /tmp/patch-necessity-audit.XXXXXX) || return 1
	trap cleanup EXIT

	if [[ -z $tree_dir ]]; then
		fetch_official_deb
		tree_dir="$claude_extract_dir"
	fi

	app_dir="$tree_dir/usr/lib/claude-desktop"
	local asar_path="$app_dir/resources/app.asar"

	if [[ ! -f $asar_path ]]; then
		echo "app.asar not found at $asar_path" >&2
		return 1
	fi

	# @electron/asar@3 (not @4): this is an operator tool run on
	# whatever Node the host happens to have, and it only ever reads an
	# asar — a job every major does identically. 3.4.1 is the last
	# release that runs on the Node 20 that Debian 13 stable ships, so
	# the audit keeps working there. The build is the one that needs
	# 4.x, and it gets it through setup_asar under the enforced
	# NODE_MIN_VERSION floor.
	_resolve_asar "$work_dir" 3 || return 1

	local contents_dir="$work_dir/app.asar.contents"
	echo 'Extracting official app.asar...'
	"$asar_exec" extract "$asar_path" "$contents_dir" || {
		echo 'Failed to extract app.asar' >&2
		return 1
	}

	build_dir="$contents_dir/.vite/build"
	main_view_js="$build_dir/mainView.js"
}

# Resolve the whole main-process bundle, not "the main JS file".
#
# There deliberately is no such single file any more (#820). Pre-3.x
# bundles kept the main process in .vite/build/index.js; 1.19367.0 split
# it into a stub plus one content-hashed chunk; 1.26832.0 dissolved that
# core entirely — index.js became a 190 KB file require()ing 83 chunks
# across two families (index.chunk-* and index2.chunk-*), with some
# anchors left behind in index.js itself. See _resolve_anchor_file in
# scripts/patches/app-asar.sh, which made the same move for the patch
# stage.
#
# This tool used to follow the single require() from the stub and grep
# whatever it landed on. On a multi-chunk tree that capture is more than
# one filename and the tool aborted ("index.js requires ... but it is
# missing"). Taking the FIRST match instead would be worse than the
# abort: every anchor living in another chunk would silently read zero,
# and a zero here is reported as `not-needed` — indistinguishable from
# an anchor upstream genuinely fixed. Those verdicts feed the deletion
# matrix in docs/learnings/official-deb-rebase-verification.md, so a
# false `not-needed` argues for deleting a patch that is still
# load-bearing.
#
# Probing the set sidesteps the resolution problem entirely: this tool
# only ever COUNTS anchors, it never edits a file, so it never has to
# decide which chunk an anchor belongs to.
_resolve_bundle() {
	# LC_ALL=C, not a bare sort: a locale-aware collation ignores
	# punctuation, so `index2.chunk-*` sorts BEFORE `index.chunk-*` in
	# en_US and after it in C. extract() answers with the first match
	# in this order, so leaving it locale-dependent makes the tool's
	# output depend on the operator's environment.
	mapfile -t bundle_js < <(
		find "$build_dir" -maxdepth 1 -name '*.js' -type f \
			| LC_ALL=C sort
	)
	if (( ${#bundle_js[@]} == 0 )); then
		echo "No .js under $build_dir — upstream layout changed?" >&2
		return 1
	fi
	echo "Probing ${#bundle_js[@]} JS file(s) under .vite/build/"
}

#-------------------------------------------------------------------------------
# Reporting
#-------------------------------------------------------------------------------

rows=()

report() {
	local name="$1" verdict="$2"
	local evidence="${*:3}"
	rows+=("$(printf '%-28s %-12s %s' "$name" "$verdict" "$evidence")")
}

# Occurrences of a PCRE across the whole bundle.
#
# -o, not -c: the shipped bytes are minified onto one line per file, so
# `grep -c` answers "files with a match" and reports 1 for a chunk
# carrying twelve. That undercount was invisible while this tool read a
# single file and is actively misleading across a set.
count() {
	LC_ALL=C grep -ohP "$1" "${bundle_js[@]}" 2>/dev/null | wc -l
}

# Same, against one named file (the preloads are probed on their own).
count_in() {
	LC_ALL=C grep -ohP "$2" "$1" 2>/dev/null | wc -l
}

# Does this PCRE occur anywhere in the bundle?
has() {
	LC_ALL=C grep -qP "$1" "${bundle_js[@]}" 2>/dev/null
}

# First capture of a PCRE across the bundle. The file list is sorted, so
# a bundle with the anchor in more than one chunk still answers the same
# way on every run rather than following readdir order.
extract() {
	LC_ALL=C grep -ohP "$1" "${bundle_js[@]}" 2>/dev/null | head -1
}

#-------------------------------------------------------------------------------
# Probes: one per legacy patch / injected file
#-------------------------------------------------------------------------------

probe_frame_fix() {
	local frameless titlebar
	frameless=$(count 'frame:\s*!1')
	titlebar=$(count 'titleBarStyle')
	if (( frameless == 0 )); then
		report 'frame-fix-wrapper' 'not-needed' \
			"no frame:!1 in the bundle (titleBarStyle refs: $titlebar," \
			'macOS/Windows-gated per teardown)'
	else
		report 'frame-fix-wrapper' 'check' \
			"frame:!1 occurs ${frameless}x — confirm Linux reachability"
	fi
}

probe_tray() {
	local tray_func inplace linux_icons
	tray_func=$(extract \
		'on\("menuBarEnabled",\(\)=>\{\K[\w$]+(?=\(\)\})')
	inplace=$(count 'setImage')
	linux_icons=$(count 'TrayIconLinux')
	if (( linux_icons > 0 && inplace > 0 )); then
		report 'tray.sh (race + icons)' 'not-needed' \
			"TrayIconLinux refs: $linux_icons, setImage refs: $inplace," \
			"menuBarEnabled fn: ${tray_func:-n/a} (in-place native)"
	else
		report 'tray.sh (race + icons)' 'check' \
			"TrayIconLinux: $linux_icons, setImage: $inplace"
	fi
}

probe_tray_template_icon() {
	local template
	template=$(count ':[$\w]+="TrayIconTemplate\.png"')
	if (( template == 0 )); then
		report 'tray icon selection' 'not-needed' \
			'no TrayIconTemplate.png assignment anchor'
	else
		report 'tray icon selection' 'needed?' \
			"TrayIconTemplate anchor present ${template}x"
	fi
}

probe_menu_bar_default() {
	if has 'menuBarEnabled:[ \t]*!0\b'; then
		report 'menuBarEnabled default' 'not-needed' \
			'defaults map ships menuBarEnabled:!0'
	else
		report 'menuBarEnabled default' 'check' \
			'defaults-map anchor absent — read the settings getter'
	fi
}

probe_quick_window() {
	local quick_var hide_anchor blurred
	quick_var=$(extract \
		'[$\w]+(?=\.setAlwaysOnTop\(\s*!0\s*,\s*"pop-up-menu"\))')
	if [[ -z $quick_var ]]; then
		report 'quick-window.sh' 'check' \
			'pop-up-menu anchor absent — quick entry restructured?'
		return
	fi
	local quick_var_re="${quick_var//\$/\\$}"
	hide_anchor=$(count "\\|\\|\\s*${quick_var_re}\\.hide\\(\\)")
	blurred=$(count "${quick_var_re}\\.blur\\(\\)")
	if (( hide_anchor > 0 && blurred == 0 )); then
		report 'quick-window.sh' 'needed?' \
			"var $quick_var: ||hide() anchor present, no blur()" \
			'— KDE focus bug likely persists; verify on Plasma'
	else
		report 'quick-window.sh' 'check' \
			"var $quick_var: hide anchors $hide_anchor, blur $blurred"
	fi
}

probe_claude_code_platform() {
	if has 'process\.platform==="linux".*linux-arm64.*linux-x64'; then
		report 'claude-code.sh' 'not-needed' \
			'getHostPlatform has native linux-x64/linux-arm64 branch'
	else
		report 'claude-code.sh' 'needed?' \
			'no linux branch found in getHostPlatform'
	fi
}

probe_org_plugins() {
	if has 'case"linux":return"/etc/claude'; then
		report 'org-plugins.sh' 'not-needed' \
			'native linux case in org-plugins path switch'
	elif has 'org-plugins'; then
		report 'org-plugins.sh' 'needed?' \
			'org-plugins resolver present, no linux case'
	else
		report 'org-plugins.sh' 'check' 'no org-plugins references'
	fi
}

probe_asar_guards() {
	local dir_check guard
	dir_check=$(count \
		'function\s+[\w$]+\s*\(\s*[\w$]+\s*\)\s*\{\s*try\s*\{\s*return\s+[\w$]+\.statSync\(')
	guard=$(count '\.endsWith\("\.asar"\)')
	report 'cowork asar-path guards' 'check' \
		"statSync/isDirectory anchors: $dir_check," \
		".asar guards upstream: $guard — official launcher passes no" \
		'asar argv, so likely not-needed'
}

probe_config_merge() {
	if has 'Config file written'; then
		report 'config.sh #400 merge' 'needed?' \
			'write anchor present — verify merge bug behaviorally'
	else
		report 'config.sh #400 merge' 'check' \
			'"Config file written" anchor absent — writer restructured'
	fi
}

probe_config_trusted_folder() {
	local param guard
	param=$(extract 'async addTrustedFolder\(\K[$\w]+(?=\)\{)')
	guard=$(count 'addTrustedFolder[^}]{0,80}endsWith\("\.asar"\)')
	if [[ -n $param && $guard -eq 0 ]]; then
		report 'config.sh #649 guards' 'needed?' \
			"addTrustedFolder($param) present, no .asar guard" \
			'— but no asar argv path on Linux; likely not-needed'
	elif [[ -z $param ]]; then
		report 'config.sh #649 guards' 'check' \
			'addTrustedFolder anchor absent'
	else
		report 'config.sh #649 guards' 'not-needed' \
			'upstream guards .asar in addTrustedFolder'
	fi
}

probe_auto_updater() {
	# managed_by_package_manager first: upstream renamed the telemetry
	# reason inside the Linux updater's early-return from
	# apt_channel_pending in the 1.18286.2 → 1.19367.0 window, when the
	# APT channel went live. The build's AU-1 tripwire
	# (_check_upstream_tripwires in scripts/patches/app-asar.sh) tracks
	# the new name; this probe was still on the old one and so reported
	# a false `check` against every current bundle. Nobody saw it
	# because the tool aborted before reaching this row (#850). Both
	# names are kept so the audit still reads older trees correctly.
	local reason
	reason=$(extract 'managed_by_package_manager|apt_channel_pending')
	if [[ -n $reason ]] || has 'apt channel not yet live'; then
		report 'autoUpdater neutering' 'not-needed' \
			"updater disabled at source (${reason:-apt channel copy})"
	else
		report 'autoUpdater neutering' 'check' \
			'kill-switch string absent — read updater bootstrap'
	fi
}

probe_wco_shim() {
	local wco
	wco=$(count_in "$main_view_js" 'windowControlsOverlay|isWindows')
	report 'wco-shim.sh' 'not-needed' \
		"official never frameless / no UA spoof (mainView refs: $wco)"
}

probe_native_binding() {
	local node_file
	node_file=$(find "$app_dir" -name '*.node' \
		-path '*claude-native*' | head -1)
	if [[ -n $node_file ]] && file "$node_file" | grep -q ELF; then
		report 'claude-native-stub' 'not-needed' \
			"real ELF binding: ${node_file#"$app_dir"/}"
	else
		report 'claude-native-stub' 'check' \
			'no ELF claude-native binding found in tree'
	fi
}

probe_node_pty() {
	local pty
	pty=$(find "$app_dir" -path '*node-pty*' -name '*.node' | head -1)
	if [[ -n $pty ]] && file "$pty" | grep -q ELF; then
		report 'node-pty rebuild' 'not-needed' \
			"prebuilt linux node-pty: ${pty#"$app_dir"/}"
	else
		report 'node-pty rebuild' 'check' 'no prebuilt node-pty found'
	fi
}

probe_cowork() {
	local helper ovmf
	helper=$(count 'cowork-linux-helper')
	ovmf=$(count '/usr/share/OVMF')
	report 'cowork.sh reroute' 'diverges' \
		"official coworkd refs: $helper, hardcoded OVMF paths: $ovmf" \
		'— 3.0.0 ships KVM-only; bwrap fallback is a 3.1 track'
}

#-------------------------------------------------------------------------------
# Run
#-------------------------------------------------------------------------------

# Guarded so tests can source this file for its probes without fetching
# a 170 MB .deb: the probes read $bundle_js, which a test sets straight
# to a fixture tree.
main() {
	_stage_tree "$@" || exit 1
	_resolve_bundle || exit 1
	run_probes

	section_header 'Patch-necessity matrix'
	printf '%-28s %-12s %s\n' 'PATCH' 'VERDICT' 'EVIDENCE'
	printf '%-28s %-12s %s\n' '-----' '-------' '--------'
	local row
	for row in "${rows[@]}"; do
		echo "$row"
	done
	section_footer 'Patch-necessity matrix'
}

run_probes() {
	probe_frame_fix
	probe_tray
	probe_tray_template_icon
	probe_menu_bar_default
	probe_quick_window
	probe_claude_code_platform
	probe_org_plugins
	probe_asar_guards
	probe_config_merge
	probe_config_trusted_folder
	probe_auto_updater
	probe_wco_shim
	probe_native_binding
	probe_node_pty
	probe_cowork
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
