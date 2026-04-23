#===============================================================================
# Cowork runtime resources: plugin shim script, architecture-specific smol-bin
# VHDX for KVM guest SDK access, and ion-dist static assets for the app://
# protocol handler used by the Third-Party Inference setup window.
#
# Sourced by: build.sh
# Sourced globals:
#   claude_extract_dir, electron_resources_dest, architecture
# Modifies globals: (none)
#===============================================================================

copy_cowork_resources() {
	section_header 'Cowork Resources'

	local resources_src="$claude_extract_dir/lib/net45/resources"

	# Copy cowork-plugin-shim.sh (used by app for MCP plugin sandboxing)
	local shim_src="$resources_src/cowork-plugin-shim.sh"
	if [[ -f $shim_src ]]; then
		cp "$shim_src" "$electron_resources_dest/cowork-plugin-shim.sh"
		chmod +x "$electron_resources_dest/cowork-plugin-shim.sh"
		echo "Copied cowork-plugin-shim.sh"
	else
		echo "Warning: cowork-plugin-shim.sh not found at $shim_src"
	fi

	# Copy smol-bin VHDX (contains SDK binaries for KVM guest VM).
	# The app copies this from resources to the bundle dir at startup
	# (win32-gated; our index.js patch extends this to Linux).
	# App looks for smol-bin.{arch}.vhdx where arch is x64 or arm64.
	local smol_arch='x64'
	if [[ $architecture == 'arm64' ]]; then
		smol_arch='arm64'
	fi
	local smol_vhdx="$resources_src/smol-bin.${smol_arch}.vhdx"
	if [[ -f $smol_vhdx ]]; then
		cp "$smol_vhdx" \
			"$electron_resources_dest/smol-bin.${smol_arch}.vhdx"
		echo "Copied smol-bin.${smol_arch}.vhdx"
	else
		echo "Warning: smol-bin VHDX not found at $smol_vhdx"
		echo "KVM Cowork will rely on virtiofs for SDK access"
	fi

	# Copy ion-dist static assets. The app registers an app:// protocol
	# handler rooted at process.resourcesPath/ion-dist; without these
	# assets, the Third-Party Inference setup window fails to load with
	# ERR_UNEXPECTED (see issue #488).
	local ion_dist_src="$resources_src/ion-dist"
	if [[ -d $ion_dist_src ]]; then
		cp -a "$ion_dist_src" "$electron_resources_dest/ion-dist"
		echo 'Copied ion-dist'
	else
		echo "Warning: ion-dist not found at $ion_dist_src" \
			'— Third-Party Inference setup will fail'
	fi

	section_footer 'Cowork Resources'
}
