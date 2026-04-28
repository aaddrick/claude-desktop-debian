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

	local tray_func tray_var first_const
	tray_func=$(grep -oP \
		'on\("menuBarEnabled",\(\)=>\{\K\w+(?=\(\)\})' "$index_js")
	if [[ -z $tray_func ]]; then
		echo 'Failed to extract tray menu function name' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo "  Found tray function: $tray_func"

	tray_var=$(grep -oP \
		"\}\);let \K\w+(?==null;(?:async )?function ${tray_func})" \
		"$index_js")
	if [[ -z $tray_var ]]; then
		echo 'Failed to extract tray variable name' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo "  Found tray variable: $tray_var"

	sed -i "s/function ${tray_func}(){/async function ${tray_func}(){/g" \
		"$index_js"

	first_const=$(grep -oP \
		"async function ${tray_func}\(\)\{.*?const \K\w+(?==)" \
		"$index_js" | head -1)
	if [[ -z $first_const ]]; then
		echo 'Failed to extract first const in function' >&2
		cd "$project_root" || exit 1
		exit 1
	fi
	echo "  Found first const variable: $first_const"

	# Add mutex guard to prevent concurrent tray rebuilds
	if ! grep -q "${tray_func}._running" "$index_js"; then
		sed -i "s/async function ${tray_func}(){/async function ${tray_func}(){if(${tray_func}._running)return;${tray_func}._running=true;setTimeout(()=>${tray_func}._running=false,1500);/g" \
			"$index_js"
		echo "  Added mutex guard to ${tray_func}()"
	fi

	# Add DBus cleanup delay after tray destroy
	if ! grep -q "await new Promise.*setTimeout" "$index_js" \
		| grep -q "$tray_var"; then
		sed -i "s/${tray_var}\&\&(${tray_var}\.destroy(),${tray_var}=null)/${tray_var}\&\&(${tray_var}.destroy(),${tray_var}=null,await new Promise(r=>setTimeout(r,250)))/g" \
			"$index_js"
		echo "  Added DBus cleanup delay after $tray_var.destroy()"
	fi

	echo 'Tray menu handler patched'
	echo '##############################################################'

	# Skip tray updates during startup (3 second window)
	echo 'Patching nativeTheme handler for startup delay...'
	if ! grep -q '_trayStartTime' "$index_js"; then
		sed -i -E \
			"s/(${electron_var_re}\.nativeTheme\.on\(\s*\"updated\"\s*,\s*\(\)\s*=>\s*\{)/let _trayStartTime=Date.now();\1/g" \
			"$index_js"
		sed -i -E \
			"s/\((\w+\([^)]*\))\s*,\s*${tray_func}\(\)\s*,/(\1,Date.now()-_trayStartTime>3e3\&\&${tray_func}(),/g" \
			"$index_js"
		echo '  Added startup delay check (3 second window)'
	fi
	echo '##############################################################'
}

patch_tray_icon_selection() {
	echo 'Patching tray icon selection for Linux visibility...'
	local index_js='app.asar.contents/.vite/build/index.js'
	local dark_check="${electron_var_re}.nativeTheme.shouldUseDarkColors"

	if grep -qP ':\$?\w+="TrayIconTemplate\.png"' "$index_js"; then
		sed -i -E \
			"s/:(\\\$?\w+)=\"TrayIconTemplate\.png\"/:\1=${dark_check}?\"TrayIconTemplate-Dark.png\":\"TrayIconTemplate.png\"/g" \
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
	local tray_func local_tray_var tray_var_re
	local menu_func path_var enabled_var enabled_count
	tray_func=$(grep -oP \
		'on\("menuBarEnabled",\(\)=>\{\K\w+(?=\(\)\})' "$index_js")
	if [[ -z $tray_func ]]; then
		echo '  Could not find tray function — skipping'
		echo '##############################################################'
		return
	fi
	local_tray_var=$(grep -oP \
		"\}\);let \K\w+(?==null;(?:async )?function ${tray_func})" \
		"$index_js")
	if [[ -z $local_tray_var ]]; then
		echo '  Could not extract tray variable name — skipping'
		echo '##############################################################'
		return
	fi
	echo "  Found tray variable: $local_tray_var"

	tray_var_re="${local_tray_var//\$/\\$}"

	menu_func=$(grep -oP "${tray_var_re}\.setContextMenu\(\K\w+(?=\(\))" \
		"$index_js" | head -1)
	if [[ -z $menu_func ]]; then
		echo '  Could not extract menu function name — skipping'
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
		"${tray_var_re}=new ${electron_var_re}\.Tray\(${electron_var_re}\.nativeImage\.createFromPath\(\K\w+(?=\))" \
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
	enabled_count=$(grep -cE \
		'const \w+\s*=\s*\w+\("menuBarEnabled"\)' "$index_js")
	if [[ $enabled_count -ne 1 ]]; then
		echo "  Expected 1 menuBarEnabled declaration, found" \
			"${enabled_count} — skipping"
		echo '##############################################################'
		return
	fi
	enabled_var=$(grep -oP \
		'const \K\w+(?=\s*=\s*\w+\("menuBarEnabled"\))' "$index_js")
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

// Anchor at the start of the existing destroy+recreate block,
// tolerating optional inner whitespace.
const reEsc = (s) => s.replace(/[.*+?^\${}()|[\\]\\\\]/g, '\\\\\$&');
const anchor = new RegExp(
  ';if\\\\(' + reEsc(T) + '&&\\\\(' + reEsc(T) + '\\\\.destroy\\\\(\\\\)'
);
if (!anchor.test(code)) {
  console.error('  [FAIL] destroy-recreate anchor not found');
  process.exit(1);
}

const fastPath =
  'if(' + T + '&&' + V + '!==false){' +
    T + '.setImage(' + E + '.nativeImage.createFromPath(' + P + '));' +
    'process.platform!==\"darwin\"&&' + T + '.setContextMenu(' + M + '());' +
    'return' +
  '}';

// Prefix the destroy block with the fast-path, keeping the matched
// portion ';if(TRAY&&(TRAY.destroy()' intact.
code = code.replace(anchor, (m) => ';' + fastPath + m.slice(1));
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
		'const \K\w+(?=\s*=\s*\w+\("menuBarEnabled"\))' \
		"$index_js" | head -1)
	if [[ -z $menu_bar_var ]]; then
		echo '  Could not extract menuBarEnabled variable name'
		echo '##############################################################'
		return
	fi
	echo "  Found menuBarEnabled variable: $menu_bar_var"

	# Change !!var to var!==false so undefined defaults to true
	if grep -qP ",\s*!!${menu_bar_var}\s*\)" "$index_js"; then
		sed -i -E \
			"s/,\s*!!${menu_bar_var}\s*\)/,${menu_bar_var}!==false)/g" \
			"$index_js"
		echo '  Patched menuBarEnabled to default to true'
	else
		echo '  menuBarEnabled pattern not found or already patched'
	fi
	echo '##############################################################'
}
