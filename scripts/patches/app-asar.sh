#===============================================================================
# app.asar patch orchestration for the official Linux tree.
#
# active_patches lists the asar patch functions that still justify
# themselves against the official bytes — the patch-zero contract: the
# default verdict for any patch is delete, and when the array is empty
# the official app.asar ships byte-identical (no extract, no repack).
#
# Each entry is a function sourced from scripts/patches/*.sh that
# operates on app.asar.contents/.vite/build/index.js relative to CWD;
# patch_app_asar runs them with CWD = $app_staging_dir/resources.
#
# Sourced by: build.sh
# Sourced globals:
#   app_staging_dir, asar_exec, work_dir, project_root, WM_CLASS
# Modifies globals: (none)
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
active_patches=(
	patch_quick_window
	patch_org_plugins_path
	patch_virtiofsd_probe
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
#   apt_channel_pending — the official updater early-returns on this
#     marker while the APT channel is pending (decision D-001). If it
#     disappears, upstream turned on self-updating, which fights the
#     package manager — the 2.x autoUpdater-noop question is live again.
#   menuBarEnabled:!0   — the settings default that keeps the menu bar
#     on. If it disappears, upstream flipped the default the deleted
#     menuBar patch used to enforce.
#
# Patterns tolerate optional whitespace so a beautified or re-minified
# bundle still matches (see CLAUDE.md, Working with Minified JavaScript).
_check_upstream_tripwires() {
	local asar_path="$1"

	if ! LC_ALL=C grep -aq 'apt_channel_pending' "$asar_path"; then
		echo 'Tripwire (AU-1): "apt_channel_pending" is gone from the' \
			'official bundle — upstream may have enabled the' \
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

	echo 'Upstream tripwires clear (autoupdater pending, menu bar on)'
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

patch_app_asar() {
	section_header 'Patch app.asar'

	local resources_dir="$app_staging_dir/resources"
	if [[ ! -f "$resources_dir/app.asar" ]]; then
		echo "No app.asar at $resources_dir — upstream layout changed?" >&2
		exit 1
	fi

	# Fail fast if upstream changed productName — a mismatch silently
	# breaks StartupWMClass in every .desktop file we ship.
	local product_name
	product_name=$(_asar_package_json_field productName \
		"$resources_dir/app.asar")
	if [[ $product_name != "$WM_CLASS" ]]; then
		echo "Error: upstream productName '$product_name' != WM_CLASS" \
			"'$WM_CLASS' — update WM_CLASS in build.sh" >&2
		exit 1
	fi
	echo "productName '$product_name' matches WM_CLASS"

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

	cd "$project_root" || exit 1
	section_footer 'Patch app.asar'
}
