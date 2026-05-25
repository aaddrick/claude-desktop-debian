#===============================================================================
# Shared patching helpers: dynamic extraction of minified variable names
# and fix-ups that multiple tray/quick-window patches rely on.
#
# Sourced by: build.sh
# Sourced globals: project_root
# Modifies globals: electron_var, electron_var_re
#===============================================================================

extract_electron_variable() {
	echo 'Extracting electron module variable name...'
	local index_js='app.asar.contents/.vite/build/index.js'

	electron_var=$(grep -oP '[$\w]+(?=\s*=\s*require\("electron"\))' \
		"$index_js" | head -1)
	if [[ -z $electron_var ]]; then
		electron_var=$(grep -oP '(?<=new )[$\w]+(?=\.Tray\b)' \
			"$index_js" | head -1)
	fi
	if [[ -z $electron_var ]]; then
		echo 'Failed to extract electron variable name' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	electron_var_re="${electron_var//\$/\\$}"
	echo "  Found electron variable: $electron_var"
	echo '##############################################################'
}

fix_native_theme_references() {
	echo 'Fixing incorrect nativeTheme variable references...'
	local index_js='app.asar.contents/.vite/build/index.js'

	local wrong_refs
	mapfile -t wrong_refs < <(
		grep -oP '[$\w]+(?=\.nativeTheme)' "$index_js" \
			| sort -u \
			| grep -Fxv "$electron_var" || true
	)

	if (( ${#wrong_refs[@]} == 0 )); then
		echo '  All nativeTheme references are correct'
		echo '##############################################################'
		return
	fi

	local ref ref_re
	for ref in "${wrong_refs[@]}"; do
		echo "  Replacing: $ref.nativeTheme -> $electron_var.nativeTheme"
		ref_re="${ref//\$/\\$}"
		sed -i -E \
			"s/${ref_re}\.nativeTheme/${electron_var_re}.nativeTheme/g" \
			"$index_js"
	done
	echo '##############################################################'
}
