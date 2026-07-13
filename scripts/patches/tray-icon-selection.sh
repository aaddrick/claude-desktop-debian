#===============================================================================
# Linux tray icon selection: honor CLAUDE_TRAY_USE_DARK_ICON.
#
# Upstream already ships TrayIconLinux.png (dark glyph, light panels)
# and TrayIconLinux-Dark.png (light glyph, dark panels) and picks
# between them from nativeTheme.shouldUseDarkColors plus a GNOME
# desktop check. Cinnamon often uses a dark panel while GTK still
# reports a light colour scheme, so the black icon lands on a dark
# gray tray (#604). The launcher probes that case and exports
# CLAUDE_TRAY_USE_DARK_ICON=1; this patch threads the flag into the
# existing ternary without replacing upstream's icons.
#
# Sourced by: build.sh
# Sourced globals: main_js (optional — set by patch_app_asar)
#===============================================================================

patch_tray_icon_selection() {
	echo 'Patching Linux tray icon selection...'
	local index_js="${main_js:-app.asar.contents/.vite/build/index.js}"
	local marker='CLAUDE_TRAY_USE_DARK_ICON'

	if grep -qF "$marker" "$index_js"; then
		echo '  Tray icon selection already patched'
		echo '##############################################################'
		return 0
	fi

	if ! grep -qF 'oPe()==="gnome"||G.nativeTheme.shouldUseDarkColors' \
		"$index_js"
	then
		echo "WARNING: Tray icon selection anchor not found in $index_js" >&2
		echo '##############################################################'
		return 0
	fi

	sed -i -E \
		's/oPe\(\)==="gnome"\|\|G\.nativeTheme\.shouldUseDarkColors/oPe()==="gnome"||G.nativeTheme.shouldUseDarkColors||process.env.CLAUDE_TRAY_USE_DARK_ICON==="1"/g' \
		"$index_js"
	echo '  Tray icon selection honors CLAUDE_TRAY_USE_DARK_ICON'
	echo '##############################################################'
}
