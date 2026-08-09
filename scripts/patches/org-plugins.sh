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
# Sourced globals: (none — resolves its own file via _resolve_anchor_file,
#   defined in app-asar.sh)
# Modifies globals: (none)
#===============================================================================

# Quote class: 1.26832.0 swapped the minifier and re-emitted nearly every
# string literal as a backtick template, so a bare " in an anchor matches
# nothing (#820). The injected case keeps double quotes on purpose — it
# is our own JS and is valid under either emission style.
_ORG_Q='[`"'"'"']'

patch_org_plugins_path() {
	# Resolve on the darwin path string, which is unique in the bundle
	# and — unlike the compound switch anchor below — is not disturbed by
	# this patch's own insertion. A resolution anchor has to be invariant
	# under its patch, or the second run fails to find the file at all,
	# before any idempotency guard can fire.
	local index_js
	index_js=$(_resolve_anchor_file 'org-plugins resolver' \
		'Application Support/Claude/org-plugins') || return 1

	# Idempotency: skip if a Linux case already exists near the
	# org-plugins path resolver (upstream may add one in the future).
	if grep -qP "case\\s*${_ORG_Q}linux${_ORG_Q}\\s*:\\s*return\\s*${_ORG_Q}/etc/claude/org-plugins" \
		"$index_js"; then
		echo 'Linux org-plugins path already present'
		return
	fi

	# Anchor: the darwin path string is unique in the entire bundle.
	# Verify it exists before attempting the patch. No quote class needed
	# — the match is on the path's interior, away from either delimiter.
	local anchor='Application Support/Claude/org-plugins'
	if ! grep -qF "$anchor" "$index_js"; then
		echo 'Warning: org-plugins path resolver not found' \
			'in this version, skipping' >&2
		return
	fi

	# Pattern (minified):
	#   ...`org-plugins`);default:return null}
	#
	# Insert case"linux":return"/etc/claude/org-plugins"; between
	# the end of the win32 case and the default case.
	#
	# \s* between tokens handles any future whitespace variation,
	# though the target file is always minified in practice.
	sed -i -E \
		"s/(${_ORG_Q}org-plugins${_ORG_Q}\\)\\s*;\\s*)(default\\s*:\\s*return\\s+null)/\\1case\"linux\":return\"\\/etc\\/claude\\/org-plugins\";\\2/" \
		"$index_js"
	echo 'Added Linux org-plugins path (/etc/claude/org-plugins)'
}
