#===============================================================================
# Inject Window Controls Overlay shim into the BrowserView preload.
#
# Sourced by: build.sh
# Sourced globals: source_dir
# Modifies globals: (none)
#===============================================================================

patch_wco_shim() {
	echo '##############################################################'
	echo 'Inlining WCO shim into mainView.js (Linux topbar workaround)'

	local main_view='app.asar.contents/.vite/build/mainView.js'

	if [[ ! -f $main_view ]]; then
		echo "Error: mainView.js not found at $main_view." >&2
		exit 1
	fi

	if grep -q '__claude_wco_shim' "$main_view"; then
		echo 'mainView.js already has WCO shim, skipping inject'
		echo '##############################################################'
		return 0
	fi

	# Sandboxed preloads can only require a fixed allowlist of modules
	# (electron, ipcRenderer, contextBridge, webFrame…). A relative
	# require to a sibling file fails with "module not found" and
	# aborts the entire preload — taking desktopBootFeatures and the
	# rest of mainView's exposeInMainWorld surface down with it.
	# So we inline the shim source directly at the top of mainView.js
	# instead of pulling it in via require.
	local shim_content
	shim_content=$(cat "$source_dir/scripts/wco-shim.js")
	local original
	original=$(cat "$main_view")
	printf '%s\n%s' "$shim_content" "$original" > "$main_view"
	echo 'Inlined WCO shim at top of mainView.js'
	echo '##############################################################'
}
