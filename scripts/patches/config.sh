#===============================================================================
# Config-related patches: preserve externally-added mcpServers across config
# writes, guard addTrustedFolder against .asar paths, and filter .asar entries
# from the --add-dir CLI dispatch and session restore.
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

# ---------------------------------------------------------------------------
# Patch: filter .asar paths from --add-dir CLI dispatch and session restore
#
# PR #640 guards the directory-check helper and addTrustedFolder IPC
# handler, but .asar paths in corrupted pre-#640 sessions survive
# restore (existsSync passes via Electron's ASAR VFS shim) and reach
# additionalDirectories -> --add-dir -> fatal Claude Code error.
#
# Fix: two sub-patches:
#   1. Filter at the --add-dir CLI dispatch loop (the single convergence
#      point for ALL code paths that feed additionalDirectories).
#   2. Filter at session restore to self-heal corrupted persisted state.
# ---------------------------------------------------------------------------
patch_asar_additional_dirs_guard() {
	echo 'Patching --add-dir dispatch to reject .asar paths (#649)...'
	local index_js='app.asar.contents/.vite/build/index.js'

	# Idempotency
	if grep -qF '.filter(_d=>!_d.endsWith(".asar"))' "$index_js"; then
		echo '  .asar --add-dir filter already present (idempotent)'
		echo '##############################################################'
		return
	fi

	if ! INDEX_JS="$index_js" node << 'ASAR_ADDDIR_PATCH'
const fs = require('fs');
const indexJs = process.env.INDEX_JS;
let code = fs.readFileSync(indexJs, 'utf8');
let patchCount = 0;

// ================================================================
// Sub-patch 1: Filter .asar from --add-dir loop
//
// Target (unique, 1 occurrence):
//   for (let O of A) Y.push("--add-dir", O);
// Fallback (if minifier uses .forEach):
//   A.forEach(O=>Y.push("--add-dir",O))
// ================================================================
{
    // Primary: for...of pattern
    const forOfRe = /for\s*\(\s*let\s+([\w$]+)\s+of\s+([\w$]+)\s*\)\s*([\w$]+)\.push\(\s*"--add-dir"\s*,\s*\1\s*\)/;
    // Fallback: .forEach pattern
    const forEachRe = /([\w$]+)\.forEach\(\s*([\w$]+)\s*=>\s*([\w$]+)\.push\(\s*"--add-dir"\s*,\s*\2\s*\)\s*\)/;

    let match = code.match(forOfRe);
    let variant = 'for-of';
    if (!match) {
        match = code.match(forEachRe);
        variant = 'forEach';
    }
    if (!match) {
        console.error('FATAL: Could not find --add-dir dispatch loop.');
        console.error('Tried: for(let X of Y) Z.push("--add-dir", X)');
        console.error('Tried: Y.forEach(X=>Z.push("--add-dir", X))');
        process.exit(1);
    }

    // Count assertion: exactly 1 match expected
    const escaped = match[0].replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const allMatches = code.match(new RegExp(escaped, 'g'));
    if (allMatches && allMatches.length > 1) {
        console.error('FATAL: --add-dir pattern matches ' +
            allMatches.length + ' times (expected 1).');
        process.exit(1);
    }

    let filtered;
    if (variant === 'for-of') {
        const [, iterVar, arrVar, pushTarget] = match;
        filtered = 'for(let ' + iterVar + ' of ' + arrVar +
            '.filter(_d=>!_d.endsWith(".asar")))' +
            pushTarget + '.push("--add-dir",' + iterVar + ')';
    } else {
        const [, arrVar, iterVar, pushTarget] = match;
        filtered = arrVar +
            '.filter(_d=>!_d.endsWith(".asar")).forEach(' +
            iterVar + '=>' + pushTarget +
            '.push("--add-dir",' + iterVar + '))';
    }
    code = code.replace(match[0], filtered);
    console.log('  Filtered .asar entries from --add-dir dispatch (' +
        variant + ' variant)');
    patchCount++;
}

// ================================================================
// Sub-patch 2: Filter .asar from session restore
//
// Anchor: "Filtering out deleted folder from session" (unique)
// Target: (VAR.userSelectedFolders||[]).filter(
// Insert: .filter(l=>!l.endsWith(".asar")) before existing .filter(
// ================================================================
{
    const anchor = 'Filtering out deleted folder from session';
    const anchorIdx = code.indexOf(anchor);
    if (anchorIdx === -1) {
        console.log('  WARNING: Session restore anchor not found — ' +
            'self-healing will not work (primary --add-dir filter ' +
            'still protects against the fatal error)');
    } else {
        const searchStart = Math.max(0, anchorIdx - 500);
        const region = code.substring(searchStart, anchorIdx);
        const usIdx = region.lastIndexOf('userSelectedFolders');
        if (usIdx === -1) {
            console.log('  WARNING: userSelectedFolders not found ' +
                'near anchor');
        } else {
            const absUsIdx = searchStart + usIdx;
            const afterUs = code.substring(absUsIdx, anchorIdx);
            const bracketRe = /\|\|\s*\[\s*\]\s*\)/;
            const bracketMatch = afterUs.match(bracketRe);
            if (!bracketMatch) {
                console.log('  WARNING: ||[]) pattern not found ' +
                    'after userSelectedFolders');
            } else {
                const insertOffset = absUsIdx + bracketMatch.index +
                    bracketMatch[0].length;
                const afterBracket = code.substring(
                    insertOffset, insertOffset + 20);
                if (!afterBracket.match(/^\s*\.filter\s*\(/)) {
                    console.log('  WARNING: .filter( not found ' +
                        'after ||[])');
                } else if (code.substring(
                    insertOffset - 50, insertOffset + 50
                ).includes('!l.endsWith(".asar")')) {
                    console.log('  Session restore .asar filter ' +
                        'already present');
                } else {
                    const injection =
                        '.filter(l=>!l.endsWith(".asar"))';
                    code = code.substring(0, insertOffset) +
                        injection + code.substring(insertOffset);
                    console.log('  Injected .asar filter in ' +
                        'session restore');
                    patchCount++;
                }
            }
        }
    }
}

fs.writeFileSync(indexJs, code);
console.log('  Applied ' + patchCount +
    ' .asar additionalDirectories patch(es)');
if (patchCount < 1) {
    console.error('FATAL: No patches applied — at minimum the ' +
        '--add-dir filter must succeed (#649).');
    process.exit(1);
}
ASAR_ADDDIR_PATCH
	then
		echo 'FATAL: .asar --add-dir filter patch failed' >&2
		echo 'Local agent mode will crash without this patch (#649).' >&2
		exit 1
	fi

	echo '##############################################################'
}
