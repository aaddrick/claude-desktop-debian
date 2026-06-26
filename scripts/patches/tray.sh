#===============================================================================
# Tray-related patches: menu handler mutex/DBus delay, icon theme selection,
# and menuBarEnabled default.
#
# Sourced by: build.sh
# Sourced globals: project_root, electron_var, electron_var_re
# Modifies globals: (none)
#===============================================================================

patch_tray_menu_handler() {
	echo 'Patching tray menu handler...'
	local index_js='app.asar.contents/.vite/build/index.js'

	local tray_func tray_func_re tray_var
	tray_func=$(grep -oP \
		'on\("menuBarEnabled",\(\)=>\{\K[\w$]+(?=\(\)\})' "$index_js")
	if [[ -z $tray_func ]]; then
		echo 'Failed to extract tray menu function name' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo "  Found tray function: $tray_func"

	# Escape `$` for PCRE / sed -E patterns where it would otherwise act
	# as an end-of-line anchor. Minifier emits identifiers like `i$A`.
	tray_func_re="${tray_func//\$/\\$}"

	tray_var=$(grep -oP \
		'[$\w]+(?=\s*=\s*new\s+[$\w]+\.Tray\()' "$index_js" | head -1)
	if [[ -z $tray_var ]]; then
		echo 'Failed to extract tray variable name' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo "  Found tray variable: $tray_var"

	# Idempotent: upstream may already ship the function as `async`
	# (1.8089.1 does). Re-applying the sed would produce
	# `async async function`, which then breaks downstream patches that
	# match `(?:async )?function NAME`.
	if ! grep -q "async function ${tray_func}(){" "$index_js"; then
		sed -i -E "s/function\s+${tray_func_re}\s*\(\s*\)\s*\{/async function ${tray_func}(){/g" \
			"$index_js"
	fi

	# Trailing-edge mutex guard. Still prevents concurrent/reentrant
	# rebuilds (the slow path's 250ms DBus await can interleave), but —
	# unlike a plain leading-edge drop — it remembers a request that
	# arrives while a rebuild is in flight and re-runs once when the
	# window clears, so the FINAL nativeTheme value wins. At startup
	# shouldUseDarkColors reads false for ~50ms, then a burst of
	# "updated" events flips it true; a dropping mutex latches the
	# initial (wrong) value and leaves the tray icon stuck black on a
	# dark panel. See docs/learnings/tray-rebuild-race.md.
	if ! grep -q "${tray_func}._running" "$index_js"; then
		sed -i -E "s/async\s+function\s+${tray_func_re}\s*\(\s*\)\s*\{/async function ${tray_func}(){if(${tray_func}._running){${tray_func}._pending=true;return}${tray_func}._running=true;setTimeout(()=>{${tray_func}._running=false;if(${tray_func}._pending){${tray_func}._pending=false;${tray_func}()}},1500);/g" \
			"$index_js"
		echo "  Added trailing-edge mutex guard to ${tray_func}()"
	fi

	# Add DBus cleanup delay after tray destroy
	tray_var_re="${tray_var//\$/\\$}"
	if ! grep -q "await new Promise.*setTimeout.*${tray_var_re}" "$index_js"; then
		sed -i -E "s/${tray_var_re}\s*\&\&\s*\(\s*${tray_var_re}\.destroy\(\)\s*,\s*${tray_var_re}\s*=\s*null\s*\)/${tray_var}\&\&(${tray_var}.destroy(),${tray_var}=null,await new Promise(r=>setTimeout(r,250)))/g" \
			"$index_js"
		echo "  Added DBus cleanup delay after $tray_var.destroy()"
	fi

	echo 'Tray menu handler patched'
	echo '##############################################################'
}

patch_tray_icon_selection() {
	echo 'Patching tray icon selection for Linux visibility...'
	local index_js='app.asar.contents/.vite/build/index.js'
	local dark_check="${electron_var_re}.nativeTheme.shouldUseDarkColors"

	if grep -qP ':[$\w]+="TrayIconTemplate\.png"' "$index_js"; then
		sed -i -E \
			"s/:([[:alnum:]_\$]+)=\"TrayIconTemplate\.png\"/:\1=${dark_check}?\"TrayIconTemplate-Dark.png\":\"TrayIconTemplate.png\"/g" \
			"$index_js"
		echo 'Patched tray icon selection for Linux theme support'
	else
		echo 'Tray icon selection pattern not found or already patched'
	fi
	echo '##############################################################'
}

patch_tray_inplace_update() {
	echo 'Patching tray rebuild to update in-place on theme change...'
	local index_js='app.asar.contents/.vite/build/index.js'

	# Re-extract the tray variable name — `patch_tray_menu_handler`
	# declares it `local` so it's not visible here. Same grep pattern.
	local tray_func tray_func_re local_tray_var tray_var_re
	local menu_func menu_var menu_var_re path_var enabled_var enabled_count
	tray_func=$(grep -oP \
		'on\("menuBarEnabled",\(\)=>\{\K[\w$]+(?=\(\)\})' "$index_js")
	if [[ -z $tray_func ]]; then
		echo '  Could not find tray function — skipping'
		echo '##############################################################'
		return
	fi
	# Escape `$` for PCRE patterns; matches the `tray_var_re` trick below.
	tray_func_re="${tray_func//\$/\\$}"
	local_tray_var=$(grep -oP \
		'[$\w]+(?=\s*=\s*new\s+[$\w]+\.Tray\()' "$index_js" | head -1)
	if [[ -z $local_tray_var ]]; then
		echo '  Could not extract tray variable name — skipping'
		echo '##############################################################'
		return
	fi
	echo "  Found tray variable: $local_tray_var"

	tray_var_re="${local_tray_var//\$/\\$}"

	# Two upstream shapes wire the context menu differently:
	#   old: ${tray_var}.setContextMenu(BUILDER())     — builder called inline
	#   new: M=BUILDER(); ${tray_var}.setContextMenu(M) — prebuilt menu object
	# Resolve the BUILDER name in both. The injected fast-path emits
	# setContextMenu(BUILDER()), so landing on the menu *object* (M) instead
	# of its builder would emit setContextMenu(M()) and throw at runtime —
	# M is a Menu instance, not a function.
	menu_func=$(grep -oP "${tray_var_re}\.setContextMenu\(\K[\$\w]+(?=\(\))" \
		"$index_js" | head -1)
	if [[ -z $menu_func ]]; then
		# Prebuilt-object form. Two traps a plain `head -1` falls into on
		# 1.13576+ bundles: (1) the *first* setContextMenu call site is a
		# menu-*clear* — `${tray_var}.setContextMenu(null)` on
		# invalidation — so latching the first arg yields the literal
		# `null`; (2) the menu object is assigned from the builder by name
		# (`M=BUILDER()`), so the builder is one hop away. Walk every
		# setContextMenu argument, skip the `null` clear, and take the
		# first that resolves to a `VAR=BUILDER()` assignment. The
		# word-boundary lookbehind resolves the assignment whether it
		# follows a separator or a declarator (`let `/`const ` leaves a
		# space before the var).
		while IFS= read -r menu_var; do
			[[ -z $menu_var || $menu_var == 'null' ]] && continue
			menu_var_re="${menu_var//\$/\\$}"
			menu_func=$(grep -oP \
				"(?<![\$\w])${menu_var_re}=\K[\$\w]+(?=\(\))" \
				"$index_js" | head -1)
			[[ -n $menu_func ]] && break
		done < <(grep -oP \
			"${tray_var_re}\.setContextMenu\(\K[\$\w]+(?=\))" "$index_js")
	fi
	if [[ -z $menu_func ]]; then
		# Both the inline grep and the menu_var fallback came up empty.
		# A silent skip here is how the #515 duplicate-icon race
		# regressed before — make it loud on stderr so the next silent
		# regression surfaces in CI logs. Still skip gracefully so the
		# build completes.
		echo "WARNING: could not resolve tray menu function" \
			"(inline + fallback both failed) — in-place" \
			"fast-path NOT applied; duplicate-icon race" \
			"(#515) may regress" >&2
		echo '##############################################################'
		return
	fi
	echo "  Found menu function: $menu_func"

	# Extract the icon-path local used in the original
	#   Nh = new pA.Tray(pA.nativeImage.createFromPath(X))
	# call. That `X` is the `const` assigned `path.join(resourcesDir(),
	# suffix)` earlier in the function; minifier renames it between
	# releases, so it needs to be extracted (not hardcoded).
	path_var=$(grep -oP \
		"${tray_var_re}=new ${electron_var_re}\.Tray\(${electron_var_re}\.nativeImage\.createFromPath\(\K[\$\w]+(?=\))" \
		"$index_js" | head -1)
	if [[ -z $path_var ]]; then
		echo '  Could not extract icon-path var — skipping'
		echo '##############################################################'
		return
	fi
	echo "  Found icon-path var: $path_var"

	# Extract the menuBarEnabled local. The injected fast-path needs to
	# read the same local that the slow-path destroy/recreate block
	# tests, so binding to the wrong site is silently broken. Bail if
	# upstream ever ships >1 declaration site instead of taking the
	# first one.
	enabled_count=$(grep -cP \
		'const [$\w]+\s*=\s*[$\w]+\("menuBarEnabled"\)' "$index_js")
	if [[ $enabled_count -ne 1 ]]; then
		echo "  Expected 1 menuBarEnabled declaration, found" \
			"${enabled_count} — skipping"
		echo '##############################################################'
		return
	fi
	enabled_var=$(grep -oP \
		'const \K[$\w]+(?=\s*=\s*[$\w]+\("menuBarEnabled"\))' "$index_js")
	if [[ -z $enabled_var ]]; then
		echo '  Could not extract menuBarEnabled var — skipping'
		echo '##############################################################'
		return
	fi
	echo "  Found menuBarEnabled var: $enabled_var"

	# Idempotency guard: re-running the patch is a no-op once our
	# fast-path is in place. Key on the distinctive
	# "setImage(EL.nativeImage.createFromPath(PATH_VAR))" sequence
	# using the (post-rename) extracted names — the destroy+recreate
	# slow-path still exists below, so we can't just count occurrences
	# of setImage.
	local fast_path_marker
	fast_path_marker="${local_tray_var}.setImage(${electron_var}.nativeImage.createFromPath(${path_var}))"
	if grep -qF "$fast_path_marker" "$index_js"; then
		echo '  In-place fast-path already present (idempotent)'
		echo '##############################################################'
		return
	fi

	# Inject a fast-path before the existing destroy+recreate block:
	# when the tray already exists and isn't being disabled, update it
	# in place with setImage + setContextMenu. Skips the DBus race
	# where Plasma briefly shows both the old (not yet unregistered)
	# and the new StatusNotifierItem. Slow path is kept for initial
	# creation and tray-disable.
	if ! TRAY_VAR="$local_tray_var" EL_VAR="$electron_var" \
		MENU_FUNC="$menu_func" PATH_VAR="$path_var" \
		ENABLED_VAR="$enabled_var" \
		node -e "
const fs = require('fs');
const p = 'app.asar.contents/.vite/build/index.js';
const T = process.env.TRAY_VAR;
const E = process.env.EL_VAR;
const M = process.env.MENU_FUNC;
const P = process.env.PATH_VAR;
const V = process.env.ENABLED_VAR;
let code = fs.readFileSync(p, 'utf8');

const fastPath =
  'if(' + T + '&&' + V + '!==false){' +
    T + '.setImage(' + E + '.nativeImage.createFromPath(' + P + '));' +
    'process.platform!==\"darwin\"&&' + T + '.setContextMenu(' + M + '());' +
    'return' +
  '}';

// Inject the fast-path just before the destroy+recreate statement.
// Locate the TRAY.destroy() call, then walk back to the ';if(' that
// opens its statement, so the fast-path lands on a clean statement
// boundary. Robust across both block shapes: the old
//   ;if(TRAY&&(TRAY.destroy()...
// and the 1.13576+ shape with leading state resets
//   ;if(X=[],Y=!1,TRAY&&(TRAY.destroy()...
const destroyMark = T + '.destroy()';
// Assert the anchor is unique before trusting indexOf's first hit: a
// second TRAY.destroy() (a new teardown path, or the string surfacing in
// a merged chunk) would silently mis-place the injection. Bail loudly so
// a future upstream surfaces here instead of shipping a wrong fast-path.
const destroyCount = code.split(destroyMark).length - 1;
if (destroyCount !== 1) {
  console.error('  [FAIL] expected exactly 1 ' + destroyMark +
    ', found ' + destroyCount);
  process.exit(1);
}
const di = code.indexOf(destroyMark);
const ifIdx = code.lastIndexOf(';if(', di);
if (ifIdx === -1) {
  console.error('  [FAIL] enclosing destroy-recreate if( not found');
  process.exit(1);
}
// Insert after the ';' so the existing if-statement stays intact.
code = code.slice(0, ifIdx + 1) + fastPath + code.slice(ifIdx + 1);
fs.writeFileSync(p, code);
console.log('  [OK] Fast-path injected before destroy-recreate');
"; then
		echo 'Failed to inject tray in-place fast-path' >&2
		cd "$project_root" || exit 1
		exit 1
	fi

	echo '##############################################################'
}

patch_menu_bar_default() {
	echo 'Patching menuBarEnabled to default to true when unset...'
	local index_js='app.asar.contents/.vite/build/index.js'

	local menu_bar_var
	menu_bar_var=$(grep -oP \
		'const \K[$\w]+(?=\s*=\s*[$\w]+\("menuBarEnabled"\))' \
		"$index_js" | head -1)
	if [[ -z $menu_bar_var ]]; then
		echo '  Could not extract menuBarEnabled variable name'
		echo '##############################################################'
		return
	fi
	echo "  Found menuBarEnabled variable: $menu_bar_var"

	# Change !!var to var!==false so undefined defaults to true.
	if grep -qP ",\s*!!${menu_bar_var}\s*\)" "$index_js"; then
		sed -i -E \
			"s/,\s*!!${menu_bar_var}\s*\)/,${menu_bar_var}!==false)/g" \
			"$index_js"
		echo '  Patched menuBarEnabled to default to true'
	# Upstream 1.13576+ moved the preference behind a settings getter
	# (Di("menuBarEnabled")) backed by a defaults map that already ships
	# `menuBarEnabled:!0` (true). When that default is present this patch
	# is a no-op by design — distinguish that from a genuine miss so a
	# future default flip back to false surfaces instead of hiding.
	elif grep -qP 'menuBarEnabled:[ \t]*!0\b' "$index_js"; then
		echo '  menuBarEnabled already defaults to true upstream' \
			'(defaults map) — no patch needed'
	else
		echo "WARNING: menuBarEnabled neither carries the legacy" \
			"!!-default anchor nor the upstream defaults-map" \
			"\`menuBarEnabled:!0\` — the tray may default OFF on a" \
			"fresh install; the default shape likely changed" >&2
	fi
	echo '##############################################################'
}
