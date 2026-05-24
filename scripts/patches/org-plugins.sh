#===============================================================================
# Linux org-plugins path: inject a case"linux" into the platform switch
# that resolves the org-plugins source directory.
#
# Upstream only has cases for darwin and win32; the default returns null,
# silently disabling the entire org-plugins marketplace feature on Linux.
# This adds: case"linux":return"/etc/claude/org-plugins"
#
# /etc/claude/org-plugins is FHS-correct for MDM-managed configuration,
# consistent with Claude Code's /etc/claude-code/ path.
#
# Sourced by: build.sh
# Sourced globals: (none)
# Modifies globals: (none)
#===============================================================================

patch_org_plugins_path() {
	local index_js='app.asar.contents/.vite/build/index.js'

	# Idempotency: skip if a Linux case already exists near the
	# org-plugins path resolver (upstream may add one in the future).
	if grep -q 'case"linux":return"/etc/claude/org-plugins"' \
		"$index_js"; then
		echo 'Linux org-plugins path already present'
		return
	fi

	# Anchor: the darwin path string is unique in the entire bundle.
	# Verify it exists before attempting the patch.
	local anchor='Application Support/Claude/org-plugins'
	if ! grep -q "$anchor" "$index_js"; then
		echo 'Warning: org-plugins path resolver not found' \
			'in this version, skipping' >&2
		return
	fi

	# Pattern (minified):
	#   ..."org-plugins");default:return null}
	#
	# The compound anchor — "org-plugins") immediately before
	# default:return null — is unique to this switch statement.
	# Insert case"linux":return"/etc/claude/org-plugins"; between
	# the end of the win32 case and the default case.
	#
	# \s* between tokens handles any future whitespace variation,
	# though the target file is always minified in practice.
	if grep -qP '"org-plugins"\)\s*;\s*default\s*:\s*return\s+null' \
		"$index_js"; then
		sed -i -E \
			's/("org-plugins"\)\s*;\s*)(default\s*:\s*return\s+null)/\1case"linux":return"\/etc\/claude\/org-plugins";\2/' \
			"$index_js"
		echo 'Added Linux org-plugins path (/etc/claude/org-plugins)'
	else
		echo 'Warning: org-plugins switch pattern not matched,' \
			'skipping' >&2
	fi
}
