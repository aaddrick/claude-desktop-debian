#===============================================================================
# Config-write guard (PARKED — not in active_patches). In-band fallback
# for the claude_desktop_config.json wipe class (#768; upstream
# anthropics/claude-code #32345 / #59640 / #63651). The PRIMARY fix is
# launcher-side backup rotation (backup_user_config in
# launcher-common.sh) — patch-zero-clean and broader-coverage; this
# stays hardened and ready to arm if the backup proves insufficient.
# Full rationale + the contrarian review that demoted it:
# docs/learnings/config-wipe-guard.md.
#
# What #768 actually hit (lead with the on-target rule, R3): the
# claude.ai renderer mirrors its grouping/starring stores into
# preferences.epitaxyPrefs on every launch via the AppPreferences
# bridge. A transient IndexedDB hydration failure hydrates those stores
# empty, and the mirror writes the empty state into epitaxyPrefs. R3
# catches exactly that.
#
# Same-class, seen upstream but NOT confirmed in #768: the config
# loader caches the parsed file once at cold start and silently falls
# back to {} on a failed read (inaccessible file, JSON-parse error,
# Zod rejection). A later whole-file write then serializes {} over a
# populated config, stubbing mcpServers / groupings / trusted folders.
# R1/R2 catch that.
#
#   R1  top-level keys present on disk but absent from the outgoing
#       object are restored (no code path legitimately deletes a
#       top-level key, so absence always means "never loaded")
#   R2  same rule per preferences.* key
#   R3  preferences.epitaxyPrefs: only when EVERY outgoing value is
#       deep-empty (the hydration-failure signature — a real session
#       carries non-empty numeric view state) restore the non-empty
#       values from disk
#
# Restores land on a lazy CLONE of the outgoing object (see the guard
# body), so a wrong R3 restore touches only the bytes on disk, never
# the live config cache — the sticky-trap the review flagged is gone.
#
# Does NOT revive the #400 Object.assign mcpServers merge: CF-1
# (2026-07-03) showed 1.18286.0 deletes entries programmatically, so a
# blind merge resurrects deleted servers. Deletions keep the key
# present, so none of R1-R3 fire on them.
#
# Known blind spots (fail-open, no worse than upstream):
#   - Corrupt-JSON cold-start (loader mode 2): the guard's own re-parse
#     of the still-corrupt disk file throws, so it writes the stub.
#     Acceptable — corrupt bytes hold no recoverable structured data.
#   - Persistent read failure (mode 1 not recovered by write time).
#   - Deliberate clear-all of every epitaxy key including paneStore
#     numerics: indistinguishable from a hydration failure, so R3 would
#     restore it (disk-only now, not sticky). Rare; launcher backup is
#     the real safety net.
#
# Sourced by: build.sh
# Sourced globals: project_root
# Modifies globals: (none)
#===============================================================================

patch_config_write_guard() {
	echo 'Patching config writer to guard against poisoned-cache wipes...'
	local index_js='app.asar.contents/.vite/build/index.js'

	# Idempotency guard
	if grep -q '_cdd_dc' "$index_js"; then
		echo '  config-write guard already present (idempotent)'
		echo '##############################################################'
		return
	fi

	# Extract variable names from the unique anchor:
	#   await WRITE_FN(PATH_VAR, CONFIG_VAR), LOGGER.info("Config file written")
	local write_fn path_var config_var write_fn_re path_var_re

	write_fn=$(grep -oP \
		'await \K[$\w]+(?=\([$\w]+,\s*[$\w]+\)\s*,\s*[$\w]+\.info\("Config file written"\))' \
		"$index_js")
	if [[ -z $write_fn ]]; then
		echo 'Tripwire (CFG-1): config-write anchor missing — could not' \
			'extract the write function around "Config file written".' \
			'Upstream reshaped the config writer; re-derive the guard' \
			'before shipping (scripts/patches/config.sh).' >&2
		return 1
	fi

	write_fn_re="${write_fn//\$/\\$}"

	path_var=$(grep -oP \
		"await ${write_fn_re}\\(\\K[\$\\w]+(?=,\\s*[\$\\w]+\\)\\s*,\\s*[\$\\w]+\\.info\\(\"Config file written\"\\))" \
		"$index_js")
	if [[ -z $path_var ]]; then
		echo 'Tripwire (CFG-1): could not extract the config path' \
			'variable — re-derive the guard before shipping.' >&2
		return 1
	fi

	path_var_re="${path_var//\$/\\$}"

	config_var=$(grep -oP \
		"await ${write_fn_re}\\(${path_var_re},\\s*\\K[\$\\w]+(?=\\)\\s*,\\s*[\$\\w]+\\.info\\(\"Config file written\"\\))" \
		"$index_js")
	if [[ -z $config_var ]]; then
		echo 'Tripwire (CFG-1): could not extract the config object' \
			'variable — re-derive the guard before shipping.' >&2
		return 1
	fi

	echo "  Write fn: $write_fn, path: $path_var, config: $config_var"

	if ! WRITE_FN="$write_fn" PATH_VAR="$path_var" CFG_VAR="$config_var" \
		node -e "
const fs = require('fs');
const p = 'app.asar.contents/.vite/build/index.js';
const W = process.env.WRITE_FN;
const P = process.env.PATH_VAR;
const C = process.env.CFG_VAR;
let code = fs.readFileSync(p, 'utf8');

const reEsc = (s) => s.replace(/[.*+?\${}()|[\\]\\\\]/g, '\\\\\$&');
// [\$\\w] not \\w: minified identifiers may contain \$
// (docs/learnings/patching-minified-js.md)
const anchorSrc =
  'await\\\\s+' + reEsc(W) + '\\\\(' + reEsc(P) + ',\\\\s*' + reEsc(C) +
  '\\\\)\\\\s*,\\\\s*[\$\\\\w]+\\\\.info\\\\(\"Config file written\"\\\\)';
const hits = code.match(new RegExp(anchorSrc, 'g')) ?? [];
if (hits.length !== 1) {
  console.error('  [FAIL] Config-write anchor matched ' + hits.length +
    ' times (expected 1)');
  process.exit(1);
}
const anchor = new RegExp(anchorSrc);

// Restores are applied to a LAZY CLONE of the outgoing object, never
// to the object itself. arA's config param is a local binding
// captured by the write closure, so reassigning it (CFG=...) feeds the
// clone to the writer while leaving the in-memory config cache (PaA)
// exactly as the renderer set it. That removes the sticky-trap: a
// wrong R3 restore (see the doc's false-positive analysis) affects
// only the bytes on disk, not live session state, and never
// re-materializes into subsequent writes.
//
// _cdd_em: deep-empty — null/[]/{} or an object whose every value is
// deep-empty. Numbers/strings/booleans are never empty, so real view
// state (rowSplit:0.5, version:0) keeps R3 from firing on live data.
const guard =
  C + '=(function(_p,_c){try{' +
  'var _cdd_dc=JSON.parse(require(\"fs\").readFileSync(_p,\"utf8\"));' +
  'if(!_cdd_dc||typeof _cdd_dc!=\"object\"||Array.isArray(_cdd_dc))return _c;' +
  'var _cdd_em=function(v){if(v==null)return!0;' +
  'if(Array.isArray(v))return v.length===0;' +
  'if(typeof v==\"object\"){for(var _cdd_i in v){' +
  'if(!_cdd_em(v[_cdd_i]))return!1}return!0}return!1};' +
  'var _cdd_o=null,_cdd_cl=function(){' +
  'return _cdd_o||(_cdd_o=Object.assign({},_c))};' +
  'for(var _cdd_k in _cdd_dc){if(_c[_cdd_k]===void 0)' +
  '_cdd_cl()[_cdd_k]=_cdd_dc[_cdd_k]}' +
  'var _cdd_dp=_cdd_dc.preferences,_cdd_cp=_c.preferences;' +
  'if(_cdd_dp&&typeof _cdd_dp==\"object\"&&_cdd_cp&&' +
  'typeof _cdd_cp==\"object\"){' +
  'var _cdd_po=null,_cdd_pcl=function(){if(!_cdd_po){' +
  '_cdd_po=Object.assign({},_cdd_cp);_cdd_cl().preferences=_cdd_po}' +
  'return _cdd_po};' +
  'for(var _cdd_p in _cdd_dp){if(_cdd_cp[_cdd_p]===void 0)' +
  '_cdd_pcl()[_cdd_p]=_cdd_dp[_cdd_p]}' +
  'var _cdd_de=_cdd_dp.epitaxyPrefs,' +
  '_cdd_ce=(_cdd_po||_cdd_cp).epitaxyPrefs;' +
  'if(_cdd_de&&typeof _cdd_de==\"object\"&&_cdd_ce&&' +
  'typeof _cdd_ce==\"object\"&&_cdd_em(_cdd_ce)&&!_cdd_em(_cdd_de)){' +
  'var _cdd_eo=Object.assign({},_cdd_ce);' +
  'for(var _cdd_g in _cdd_de){if(!_cdd_em(_cdd_de[_cdd_g]))' +
  '_cdd_eo[_cdd_g]=_cdd_de[_cdd_g]}' +
  '_cdd_pcl().epitaxyPrefs=_cdd_eo}' +
  '}' +
  'return _cdd_o||_c;' +
  '}catch(_cdd_ex){return _c}})(' + P + ',' + C + ')';

code = code.replace(anchor, (m) => guard + ';' + m);
fs.writeFileSync(p, code);
console.log('  [OK] config-write wipe guard injected before config write');
"; then
		echo 'Failed to inject config write guard' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	echo '##############################################################'
}
