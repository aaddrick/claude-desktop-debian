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
work_dir=$(mktemp -d /tmp/patch-necessity-audit.XXXXXX)
tree_dir=''
local_deb_path=''

usage() {
	sed -n '2,20p' "${BASH_SOURCE[0]}"
	exit "${1:-0}"
}

while (( $# )); do
	case "$1" in
		--deb)	local_deb_path="$2"; shift 2 ;;
		--tree)	tree_dir="$2"; shift 2 ;;
		-h|--help)	usage ;;
		*)	echo "Unknown argument: $1" >&2; usage 1 ;;
	esac
done

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT

#-------------------------------------------------------------------------------
# Acquire the tree
#-------------------------------------------------------------------------------

if [[ -z $tree_dir ]]; then
	fetch_official_deb
	tree_dir="$claude_extract_dir"
fi

app_dir="$tree_dir/usr/lib/claude-desktop"
resources_dir="$app_dir/resources"
asar_path="$resources_dir/app.asar"

if [[ ! -f $asar_path ]]; then
	echo "app.asar not found at $asar_path" >&2
	exit 1
fi

asar_exec='npx --yes @electron/asar'
if command -v asar &> /dev/null; then
	asar_exec='asar'
fi

contents_dir="$work_dir/app.asar.contents"
echo 'Extracting official app.asar...'
$asar_exec extract "$asar_path" "$contents_dir" || {
	echo 'Failed to extract app.asar' >&2
	exit 1
}

build_dir="$contents_dir/.vite/build"
index_js="$build_dir/index.js"
main_view_js="$build_dir/mainView.js"

if [[ ! -f $index_js ]]; then
	echo "index.js not found in extracted asar" >&2
	exit 1
fi

# Since upstream 1.19367.0 the main process is code-split: index.js is a
# stub that require()s a content-hashed main chunk. Follow it to the real
# code so the anchor counts below don't all read zero off the stub (the
# same resolution _resolve_main_js does in scripts/patches/app-asar.sh).
# Older single-file bundles have no such require and keep index.js.
main_chunk=$(grep -oP 'require\("\./\Kindex\.chunk-[^"]+\.js(?="\))' \
	"$index_js")
if [[ -n $main_chunk ]]; then
	if [[ ! -f "$build_dir/$main_chunk" ]]; then
		echo "index.js requires $main_chunk but it is missing" >&2
		exit 1
	fi
	index_js="$build_dir/$main_chunk"
fi

#-------------------------------------------------------------------------------
# Reporting
#-------------------------------------------------------------------------------

rows=()

report() {
	local name="$1" verdict="$2"
	local evidence="${*:3}"
	rows+=("$(printf '%-28s %-12s %s' "$name" "$verdict" "$evidence")")
}

count() {
	LC_ALL=C grep -cP "$1" "$2" 2>/dev/null || true
}

#-------------------------------------------------------------------------------
# Probes: one per legacy patch / injected file
#-------------------------------------------------------------------------------

probe_frame_fix() {
	local frameless titlebar
	frameless=$(count 'frame:\s*!1' "$index_js")
	titlebar=$(count 'titleBarStyle' "$index_js")
	if (( frameless == 0 )); then
		report 'frame-fix-wrapper' 'not-needed' \
			"no frame:!1 in index.js (titleBarStyle refs: $titlebar," \
			'macOS/Windows-gated per teardown)'
	else
		report 'frame-fix-wrapper' 'check' \
			"frame:!1 occurs ${frameless}x — confirm Linux reachability"
	fi
}

probe_tray() {
	local tray_func inplace linux_icons
	tray_func=$(LC_ALL=C grep -oP \
		'on\("menuBarEnabled",\(\)=>\{\K[\w$]+(?=\(\)\})' "$index_js" |
		head -1)
	inplace=$(count 'setImage' "$index_js")
	linux_icons=$(count 'TrayIconLinux' "$index_js")
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
	template=$(count ':[$\w]+="TrayIconTemplate\.png"' "$index_js")
	if (( template == 0 )); then
		report 'tray icon selection' 'not-needed' \
			'no TrayIconTemplate.png assignment anchor'
	else
		report 'tray icon selection' 'needed?' \
			"TrayIconTemplate anchor present ${template}x"
	fi
}

probe_menu_bar_default() {
	if LC_ALL=C grep -qP 'menuBarEnabled:[ \t]*!0\b' "$index_js"; then
		report 'menuBarEnabled default' 'not-needed' \
			'defaults map ships menuBarEnabled:!0'
	else
		report 'menuBarEnabled default' 'check' \
			'defaults-map anchor absent — read the settings getter'
	fi
}

probe_quick_window() {
	local quick_var hide_anchor blurred
	quick_var=$(LC_ALL=C grep -oP \
		'[$\w]+(?=\.setAlwaysOnTop\(\s*!0\s*,\s*"pop-up-menu"\))' \
		"$index_js" | head -1)
	if [[ -z $quick_var ]]; then
		report 'quick-window.sh' 'check' \
			'pop-up-menu anchor absent — quick entry restructured?'
		return
	fi
	local quick_var_re="${quick_var//\$/\\$}"
	hide_anchor=$(count "\\|\\|\\s*${quick_var_re}\\.hide\\(\\)" "$index_js")
	blurred=$(count "${quick_var_re}\\.blur\\(\\)" "$index_js")
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
	if LC_ALL=C grep -q \
		'process.platform==="linux".*linux-arm64.*linux-x64' "$index_js"
	then
		report 'claude-code.sh' 'not-needed' \
			'getHostPlatform has native linux-x64/linux-arm64 branch'
	else
		report 'claude-code.sh' 'needed?' \
			'no linux branch found in getHostPlatform'
	fi
}

probe_org_plugins() {
	if LC_ALL=C grep -q 'case"linux":return"/etc/claude' "$index_js"; then
		report 'org-plugins.sh' 'not-needed' \
			'native linux case in org-plugins path switch'
	elif LC_ALL=C grep -q 'org-plugins' "$index_js"; then
		report 'org-plugins.sh' 'needed?' \
			'org-plugins resolver present, no linux case'
	else
		report 'org-plugins.sh' 'check' 'no org-plugins references'
	fi
}

probe_asar_guards() {
	local dir_check guard
	dir_check=$(count \
		'function\s+[\w$]+\s*\(\s*[\w$]+\s*\)\s*\{\s*try\s*\{\s*return\s+[\w$]+\.statSync\(' \
		"$index_js")
	guard=$(count '\.endsWith\("\.asar"\)' "$index_js")
	report 'cowork asar-path guards' 'check' \
		"statSync/isDirectory anchors: $dir_check," \
		".asar guards upstream: $guard — official launcher passes no" \
		'asar argv, so likely not-needed'
}

probe_config_merge() {
	if LC_ALL=C grep -q 'Config file written' "$index_js"; then
		report 'config.sh #400 merge' 'needed?' \
			'write anchor present — verify merge bug behaviorally'
	else
		report 'config.sh #400 merge' 'check' \
			'"Config file written" anchor absent — writer restructured'
	fi
}

probe_config_trusted_folder() {
	local param guard
	param=$(LC_ALL=C grep -oP 'async addTrustedFolder\(\K[$\w]+(?=\)\{)' \
		"$index_js" | head -1)
	guard=$(count 'addTrustedFolder[^}]{0,80}endsWith\("\.asar"\)' \
		"$index_js")
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
	if LC_ALL=C grep -q 'apt_channel_pending\|apt channel not yet live' \
		"$index_js"; then
		report 'autoUpdater neutering' 'not-needed' \
			'updater disabled at source (apt_channel_pending)'
	else
		report 'autoUpdater neutering' 'check' \
			'kill-switch string absent — read updater bootstrap'
	fi
}

probe_wco_shim() {
	local wco
	wco=$(count 'windowControlsOverlay|isWindows' "$main_view_js")
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
	helper=$(count 'cowork-linux-helper' "$index_js")
	ovmf=$(count '/usr/share/OVMF' "$index_js")
	report 'cowork.sh reroute' 'diverges' \
		"official coworkd refs: $helper, hardcoded OVMF paths: $ovmf" \
		'— 3.0.0 ships KVM-only; bwrap fallback is a 3.1 track'
}

#-------------------------------------------------------------------------------
# Run
#-------------------------------------------------------------------------------

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

section_header 'Patch-necessity matrix'
printf '%-28s %-12s %s\n' 'PATCH' 'VERDICT' 'EVIDENCE'
printf '%-28s %-12s %s\n' '-----' '-------' '--------'
for row in "${rows[@]}"; do
	echo "$row"
done
section_footer 'Patch-necessity matrix'
