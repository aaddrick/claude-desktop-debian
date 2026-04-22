#===============================================================================
# ion-dist staging: copy the ion-dist frontend assets directory into
# Electron's resources dir.  The app's custom app:// protocol handler
# serves files from process.resourcesPath/ion-dist; without it every
# internal page load returns ERR_UNEXPECTED and the UI shows
# "Couldn't Connect to Claude".
#
# Sourced by: build.sh
# Sourced globals:
#   claude_extract_dir, electron_resources_dest
# Modifies globals: (none)
#===============================================================================

copy_ion_dist() {
	section_header 'ion-dist Frontend Assets'

	local ion_dist_src="$claude_extract_dir/lib/net45/resources/ion-dist"

	if [[ -d $ion_dist_src ]]; then
		echo 'Copying ion-dist to Electron resources directory...'
		cp -a "$ion_dist_src" "$electron_resources_dest/ion-dist" \
			|| exit 1
		echo 'ion-dist frontend assets copied'
	else
		echo 'Warning: ion-dist directory not found in Claude' \
			"installer at $ion_dist_src"
		echo 'The app:// protocol handler will fail without it'
	fi

	section_footer 'ion-dist Frontend Assets'
}
