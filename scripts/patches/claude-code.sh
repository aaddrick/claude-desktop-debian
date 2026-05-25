#===============================================================================
# Linux support in Claude Code's getHostPlatform: route linux-* bundles
# through the normal platform switch instead of throwing.
#
# Sourced by: build.sh
# Sourced globals: (none)
# Modifies globals: (none)
#===============================================================================

patch_linux_claude_code() {
	local index_js='app.asar.contents/.vite/build/index.js'
	if grep -q 'process.platform==="linux".*linux-arm64.*linux-x64' "$index_js"; then
		echo 'Linux claude code binary support already present'
		return
	fi

	# New format (Claude >= 1.1.3541): getHostPlatform includes arch detection for win32
	# Pattern: if(process.platform==="win32")return e==="arm64"?"win32-arm64":"win32-x64";throw new Error(...)
	if grep -qP 'if\s*\(\s*process\.platform\s*===\s*"win32"\s*\)\s*return\s+[$\w]+\s*===\s*"arm64"\s*\?\s*"win32-arm64"\s*:\s*"win32-x64"\s*;\s*throw' "$index_js"; then
		sed -i -E 's/if\s*\(\s*process\.platform\s*===\s*"win32"\s*\)\s*return\s+([[:alnum:]_$]+)\s*===\s*"arm64"\s*\?\s*"win32-arm64"\s*:\s*"win32-x64"\s*;\s*throw/if(process.platform==="win32")return \1==="arm64"?"win32-arm64":"win32-x64";if(process.platform==="linux")return \1==="arm64"?"linux-arm64":"linux-x64";throw/' "$index_js"
		echo 'Added linux claude code support (new arch-aware format)'
	# Old format (Claude <= 1.1.3363): no arch detection for win32
	elif grep -qP 'if\s*\(\s*process\.platform\s*===\s*"win32"\s*\)\s*return\s*"win32-x64"\s*;' "$index_js"; then
		sed -i -E 's/if\s*\(\s*process\.platform\s*===\s*"win32"\s*\)\s*return\s*"win32-x64"\s*;/if(process.platform==="win32")return"win32-x64";if(process.platform==="linux")return process.arch==="arm64"?"linux-arm64":"linux-x64";/' "$index_js"
		echo 'Added linux claude code support (legacy format)'
	else
		echo 'Warning: Could not find getHostPlatform pattern to patch for Linux claude code support'
	fi
}
