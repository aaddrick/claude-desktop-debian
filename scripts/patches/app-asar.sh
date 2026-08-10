#===============================================================================
# app.asar patch orchestration for the official Linux tree.
#
# active_patches lists the asar patch functions that still justify
# themselves against the official bytes — the patch-zero contract: the
# default verdict for any patch is delete, and when the array is empty
# the official app.asar ships byte-identical (no extract, no repack).
#
# Each entry is a function sourced from scripts/patches/*.sh that edits
# the main-process JS relative to CWD; patch_app_asar runs them with
# CWD = $app_staging_dir/resources. Each patch resolves the file its own
# anchor lives in via _resolve_anchor_file — there is no single
# main-process file to hand them all (see that function's comment).
#
# Sourced by: build.sh
# Sourced globals:
#   app_staging_dir, asar_exec, work_dir, project_root
# Modifies globals: WM_CLASS (derived + exported)
#===============================================================================

# Survivor candidates per docs/learnings/official-deb-rebase-verification.md:
#   patch_quick_window       — Electron-on-KDE stale-focus bug: official
#                              bundle still hides without blur() (pending
#                              Plasma repro; drop if it doesn't reproduce)
#   patch_org_plugins_path   — upstream platform switch has no linux case,
#                              so MDM org plugins are dead on Linux without
#                              this (filed upstream)
#   patch_virtiofsd_probe    — upstream resolves virtiofsd from two paths
#                              plus an Ubuntu-22-only bundled fallback, so
#                              Cowork reports "requires QEMU" on
#                              Arch/Debian/Pop with a complete KVM stack
#                              (#771/#772; filed upstream)
#   patch_cowork_bwrap       — opt-in bubblewrap Cowork backend for hosts
#                              without KVM/vhost-vsock (ChromeOS Crostini,
#                              #772). Every branch is gated on
#                              COWORK_VM_BACKEND=bwrap, so unflagged
#                              launches ship the official path unchanged.
#   patch_tray_icon_env_override — Cinnamon can use a dark panel while
#                              GTK still reports a light colour scheme,
#                              so upstream's shouldUseDarkColors
#                              heuristic picks the wrong PNG (#604).
#                              The launcher exports
#                              CLAUDE_TRAY_USE_DARK_ICON; this threads
#                              it into the existing ternary. Interim
#                              pending upstream (anthropics/claude-code
#                              #77170); its hard-fail anchor is the
#                              retirement tripwire.
active_patches=(
	patch_quick_window
	patch_org_plugins_path
	patch_virtiofsd_probe
	patch_cowork_bwrap
	patch_tray_icon_env_override
)

# The #768 config-wipe guard (config.sh) is NOT wired: a contrarian
# review (see docs/learnings/config-wipe-guard.md) established that the
# primary fix is launcher-side backup rotation (backup_user_config in
# launcher-common.sh) — patch-zero-clean, out of app.asar, and covers
# the corrupt-JSON / ENOENT / single-bad-entry Zod modes an in-band
# guard misses. config.sh stays sourced-but-parked as the ready-to-arm
# fallback. Its sibling local-stores.sh was deleted outright: its
# "does-not-JSON-parse" rule missed the throwing Zod loader (WBn.parse)
# that produces spaces.json's real wipe.

# AU-1/MB-1: build-time tripwires on upstream behavior we deleted
# patches for. Each deleted patch used to WARN at patch time when its
# anchor moved; with the patches gone, an upstream flip would land
# silently. Grep the asar directly (asar stores file contents
# uncompressed) so the check also runs in patch-zero mode, where the
# archive is never extracted.
#
#   managed_by_package_manager — the telemetry reason inside the
#     Linux build's constant-folded updater early-return ("[updater]
#     Linux: in-app updater off (updates via apt)"). Renamed by
#     upstream from apt_channel_pending in the 1.18286.2 → 1.19367.0
#     window when the APT channel went live: Linux updates are now
#     permanently the package manager's job (decision D-001). If it
#     disappears, upstream rewrote that gate and may have turned on
#     self-updating, which fights the package manager — the 2.x
#     autoUpdater-noop question is live again.
#   menuBarEnabled:!0   — the settings default that keeps the menu bar
#     on. If it disappears, upstream flipped the default the deleted
#     menuBar patch used to enforce.
#
# Patterns tolerate optional whitespace so a beautified or re-minified
# bundle still matches (see CLAUDE.md, Working with Minified JavaScript).
_check_upstream_tripwires() {
	local asar_path="$1"

	if ! LC_ALL=C grep -aq 'managed_by_package_manager' "$asar_path"
	then
		echo 'Tripwire (AU-1): "managed_by_package_manager" is gone' \
			'from the official bundle — upstream may have enabled the' \
			'autoupdater. Re-evaluate before shipping (see' \
			'docs/decisions.md D-001).' >&2
		exit 1
	fi

	if ! LC_ALL=C grep -aqE 'menuBarEnabled:[[:space:]]*!0' "$asar_path"
	then
		echo 'Tripwire (MB-1): "menuBarEnabled:!0" is gone from the' \
			'official bundle — upstream may have flipped the menu-bar' \
			'default. Re-evaluate before shipping.' >&2
		exit 1
	fi

	echo 'Upstream tripwires clear (updater off on Linux, menu bar on)'
}

# Read one field out of the asar's package.json without a full extract.
_asar_package_json_field() {
	local field="$1"
	local asar_path="$2"
	local meta_dir="$work_dir/asar-meta"

	rm -rf "$meta_dir"
	mkdir -p "$meta_dir" || return 1
	(cd "$meta_dir" && "$asar_exec" extract-file "$asar_path" package.json) \
		|| return 1
	node -e 'console.log(require(process.argv[1])[process.argv[2]] ?? "")' \
		"$meta_dir/package.json" "$field"
}

# Derive the WM_CLASS / StartupWMClass value from the asar's
# package.json desktopName (#779). Chromium derives the runtime X11
# WM_CLASS / Wayland app_id from that field minus its .desktop suffix
# — not from the ELF basename, the launcher's --class flag, or
# productName. Upstream has renamed it once already
# (claude-desktop.desktop → com.anthropic.Claude.desktop across
# 1.18286.0 → 1.19367.0), so any hardcoded value silently breaks
# window-to-launcher grouping on the next rename. Verified live on
# GNOME and KDE against both releases (see #786).
_derive_wm_class() {
	local desktop_name="$1"

	if [[ -z $desktop_name ]]; then
		echo 'Error: package.json desktopName is missing/empty — cannot' \
			'derive WM_CLASS. Upstream moved the field Chromium reads' \
			'the window class from; re-verify before shipping (#779).' >&2
		return 1
	fi
	if [[ $desktop_name != *.desktop ]]; then
		echo "Error: desktopName '$desktop_name' has no .desktop" \
			'suffix — upstream changed its shape; re-verify how Chromium' \
			'derives the window class before shipping (#779).' >&2
		return 1
	fi
	printf '%s\n' "${desktop_name%.desktop}"
}

# Resolve the single .vite/build file whose bytes carry an anchor, and
# echo its path relative to the resources CWD.
#
# There is deliberately no "the main JS file" any more. Pre-3.x bundles
# kept the whole main process in .vite/build/index.js; 1.19367.0 split it
# into a stub plus one content-hashed main chunk; 1.26832.0 dissolved
# that core entirely — index.js became a 190 KB file require()ing 83
# chunks, across two chunk families (index.chunk-* and index2.chunk-*),
# with the tray anchor left behind in index.js itself. A single resolved
# path cannot serve every patch, so each anchor resolves its own file
# (#820, docs/learnings/patching-minified-js.md).
#
# Takes a PCRE for the FULL anchor shape, not just its distinctive
# string: on 1.26832.0 the literal `pop-up-menu` occurs in two chunks but
# only one carries the setAlwaysOnTop call quick-window rewrites, so
# resolving on the string alone picks a decoy. Asserting exactly one
# match is what replaces the old multi-chunk guard: zero or many is a
# hard error rather than a silent mispatch.
#
# Anchors must be written with a quote class ([`"']) rather than a bare
# double quote — 1.26832.0 swapped the minifier and re-emitted nearly
# every string literal as a backtick template.
_resolve_anchor_file() {
	local label="$1"
	local pattern="$2"
	local build_dir='app.asar.contents/.vite/build'

	if [[ ! -d $build_dir ]]; then
		echo "No $build_dir — upstream layout changed?" >&2
		return 1
	fi

	# -z treats each file as one record so an anchor's \s* can span a
	# newline. Shipped bytes are single-line, but a beautified reference
	# bundle wraps the same expression across lines and a line-oriented
	# grep would report it missing (the beautified false-negative trap in
	# docs/learnings/patching-minified-js.md).
	local -a hits
	mapfile -t hits < <(
		grep -rlPz --include='*.js' -- "$pattern" "$build_dir" 2>/dev/null \
			| sort
	)

	if (( ${#hits[@]} == 0 )); then
		echo "Anchor '$label' matched no file under $build_dir —" \
			'upstream reshaped or removed it. Re-derive the anchor' \
			'before shipping (#820).' >&2
		return 1
	fi
	if (( ${#hits[@]} > 1 )); then
		echo "Anchor '$label' matched ${#hits[@]} files (${hits[*]}) —" \
			'ambiguous. Tighten the anchor to the full shape so it' \
			'selects one file (#820).' >&2
		return 1
	fi

	printf '%s\n' "${hits[0]}"
}

patch_app_asar() {
	section_header 'Patch app.asar'

	local resources_dir="$app_staging_dir/resources"
	if [[ ! -f "$resources_dir/app.asar" ]]; then
		echo "No app.asar at $resources_dir — upstream layout changed?" >&2
		exit 1
	fi

	# Derive WM_CLASS from the field Chromium actually reads (see
	# _derive_wm_class above). Exported because the packaging scripts
	# that interpolate it into .desktop files and launcher-common.sh
	# run as child processes of build.sh.
	local desktop_name
	desktop_name=$(_asar_package_json_field desktopName \
		"$resources_dir/app.asar")
	WM_CLASS=$(_derive_wm_class "$desktop_name") || exit 1
	export WM_CLASS
	echo "WM_CLASS '$WM_CLASS' derived from desktopName '$desktop_name'"

	# productName stays tripwired separately: it no longer feeds
	# WM_CLASS, but Electron's userData path (~/.config/Claude) keys on
	# it, and the launcher, doctor, and docs all assume that location.
	local product_name
	product_name=$(_asar_package_json_field productName \
		"$resources_dir/app.asar")
	if [[ $product_name != 'Claude' ]]; then
		echo "Error: upstream productName '$product_name' != 'Claude'" \
			'— the ~/.config/Claude userData assumption broke; re-audit' \
			'the launcher and doctor paths before shipping.' >&2
		exit 1
	fi
	echo "productName '$product_name' unchanged (userData path holds)"

	# Runs against the pristine bytes, before any patch touches them.
	_check_upstream_tripwires "$resources_dir/app.asar"

	if (( ${#active_patches[@]} == 0 )); then
		echo 'active_patches is empty — shipping the official app.asar' \
			'byte-identical (patch-zero)'
		section_footer 'Patch app.asar'
		return 0
	fi

	echo "Active asar patches: ${active_patches[*]}"
	cd "$resources_dir" || exit 1
	"$asar_exec" extract app.asar app.asar.contents || exit 1

	# Layout census, informational only — each patch resolves the file
	# its own anchor lives in (see _resolve_anchor_file). Printed so a
	# build log still records when upstream reshapes the bundle.
	local build_dir='app.asar.contents/.vite/build'
	# grep -o | wc -l, not grep -c: the bundle is near-single-line, so
	# grep -c would report matching LINES (a handful) rather than matches.
	local js_count chunk_count
	js_count=$(find "$build_dir" -name '*.js' -type f | wc -l)
	chunk_count=$(grep -oP 'require\("\./index2?\.chunk-[^"]+\.js"\)' \
		"$build_dir/index.js" 2>/dev/null | wc -l)
	echo "Bundle layout: $js_count JS files under .vite/build," \
		"$chunk_count chunk requires from index.js"

	local patch_fn
	for patch_fn in "${active_patches[@]}"; do
		"$patch_fn" || exit 1
	done

	# Repack, preserving upstream's unpacked set exactly. The unpack
	# expression is derived from the shipped app.asar.unpacked tree
	# rather than hardcoded, so upstream can add native helpers without
	# breaking the build. asar pack honors only ONE --unpack expression,
	# so every unpacked path is folded into a single brace glob.
	local unpack_files unpack_glob
	mapfile -t unpack_files < <(
		cd app.asar.unpacked && find . -type f | sed 's|^\./||' | sort
	)
	if (( ${#unpack_files[@]} == 0 )); then
		echo 'Warning: official app.asar.unpacked is empty —' \
			'packing without --unpack'
		"$asar_exec" pack app.asar.contents app.asar || exit 1
	else
		unpack_glob=$(IFS=,; echo "${unpack_files[*]}")
		(( ${#unpack_files[@]} > 1 )) && unpack_glob="{$unpack_glob}"
		"$asar_exec" pack app.asar.contents app.asar \
			--unpack "$unpack_glob" || exit 1

		# The repack rewrote app.asar.unpacked; diverging from the
		# upstream set means a native helper got inlined (or dropped)
		# and would fail at runtime.
		local repacked_files
		mapfile -t repacked_files < <(
			cd app.asar.unpacked && find . -type f | sed 's|^\./||' | sort
		)
		if [[ "${unpack_files[*]}" != "${repacked_files[*]}" ]]; then
			echo 'Error: repacked app.asar.unpacked diverges from the' \
				'upstream unpacked set' >&2
			exit 1
		fi
	fi

	# The extracted contents must not leak into the packaged tree.
	rm -rf app.asar.contents

	# Ship the bwrap fallback daemon beside app.asar (in resources/,
	# i.e. process.resourcesPath) when its patch is active. It sits
	# OUTSIDE the asar on purpose: child_process cannot exec a script
	# from inside an asar, and keeping it out of app.asar.unpacked keeps
	# the repack invariant above pinned to upstream's set. The file is
	# inert unless the user launches with COWORK_VM_BACKEND=bwrap.
	local p
	for p in "${active_patches[@]}"; do
		if [[ $p == 'patch_cowork_bwrap' ]]; then
			cp "$project_root/scripts/cowork-fallback/cowork-vm-service.js" \
				"$resources_dir/cowork-vm-service.js" || exit 1
			echo 'Cowork bwrap daemon staged at resources/cowork-vm-service.js'
			break
		fi
	done

	cd "$project_root" || exit 1
	section_footer 'Patch app.asar'
}
