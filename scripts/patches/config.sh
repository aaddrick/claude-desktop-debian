#===============================================================================
# Config-related patches: preserve externally-added mcpServers across config
# writes, and guard addTrustedFolder against .asar paths.
#
# Sourced by: build.sh
# Sourced globals: project_root
# Modifies globals: (none)
#===============================================================================

patch_config_write_merge() {
	echo 'Patching config writer to preserve mcpServers from disk...'
	local index_js='app.asar.contents/.vite/build/index.js'

	# Idempotency guard
	if grep -q '_cdd_dc' "$index_js"; then
		echo '  mcpServers merge already present (idempotent)'
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
		echo '  Could not extract write function name — skipping' >&2
		echo '##############################################################'
		return
	fi

	write_fn_re="${write_fn//\$/\\$}"

	path_var=$(grep -oP \
		"await ${write_fn_re}\\(\\K[\$\\w]+(?=,\\s*[\$\\w]+\\)\\s*,\\s*[\$\\w]+\\.info\\(\"Config file written\"\\))" \
		"$index_js")
	if [[ -z $path_var ]]; then
		echo '  Could not extract path variable — skipping' >&2
		echo '##############################################################'
		return
	fi

	path_var_re="${path_var//\$/\\$}"

	config_var=$(grep -oP \
		"await ${write_fn_re}\\(${path_var_re},\\s*\\K[\$\\w]+(?=\\)\\s*,\\s*[\$\\w]+\\.info\\(\"Config file written\"\\))" \
		"$index_js")
	if [[ -z $config_var ]]; then
		echo '  Could not extract config variable — skipping' >&2
		echo '##############################################################'
		return
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
const anchor = new RegExp(
  'await\\\\s+' + reEsc(W) + '\\\\(' + reEsc(P) + ',\\\\s*' + reEsc(C) +
  '\\\\)\\\\s*,\\\\s*\\\\w+\\\\.info\\\\(\"Config file written\"\\\\)'
);
if (!anchor.test(code)) {
  console.error('  [FAIL] Config-write anchor not found');
  process.exit(1);
}

const merge =
  'try{var _cdd_dc=JSON.parse(require(\"fs\").readFileSync(' + P +
  ',\"utf8\"));if(_cdd_dc.mcpServers){' + C +
  '.mcpServers=Object.assign({},_cdd_dc.mcpServers,' + C +
  '.mcpServers||{})}}catch(_cdd_ex){}';

code = code.replace(anchor, (m) => merge + ';' + m);
fs.writeFileSync(p, code);
console.log('  [OK] mcpServers merge injected before config write');
"; then
		echo 'Failed to inject config write merge' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	echo '##############################################################'
}

patch_asar_trusted_folder_guard() {
	echo 'Patching addTrustedFolder to reject .asar paths...'
	local index_js='app.asar.contents/.vite/build/index.js'

	# Idempotency guard
	if grep -qF 'endsWith(".asar"))return' "$index_js"; then
		echo '  .asar guard already present (idempotent)'
		echo '##############################################################'
		return
	fi

	local folder_param
	folder_param=$(grep -oP \
		'LocalAgentModeSessions\.addTrustedFolder: \$\{\K[$\w]+(?=\})' \
		"$index_js")
	if [[ -z $folder_param ]]; then
		echo '  Could not extract folder parameter — skipping' >&2
		echo '##############################################################'
		return
	fi
	echo "  Found folder parameter: $folder_param"

	if ! FOLDER_PARAM="$folder_param" node -e "
const fs = require('fs');
const p = 'app.asar.contents/.vite/build/index.js';
const F = process.env.FOLDER_PARAM;
let code = fs.readFileSync(p, 'utf8');

const anchor = 'LocalAgentModeSessions.addTrustedFolder: \${' + F + '}\`);';
const idx = code.indexOf(anchor);
if (idx === -1) {
  console.error('  [FAIL] addTrustedFolder anchor not found');
  process.exit(1);
}

const insertPoint = idx + anchor.length;
const guard = 'if(' + F + '.endsWith(\".asar\"))return;';
code = code.slice(0, insertPoint) + guard + code.slice(insertPoint);
fs.writeFileSync(p, code);
console.log('  [OK] .asar guard injected in addTrustedFolder');
"; then
		echo 'Failed to inject .asar trusted folder guard' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	echo '##############################################################'
}
