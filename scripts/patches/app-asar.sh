#===============================================================================
# Top-level app.asar patch orchestration: extract, wrap entry point, stub
# native module, copy i18n and tray icons, then invoke per-feature patches.
#
# Sourced by: build.sh
# Sourced globals:
#   claude_extract_dir, app_staging_dir, asar_exec, source_dir
# Modifies globals: (none directly — delegated patches may mutate electron_var)
#===============================================================================

patch_app_asar() {
	echo 'Processing app.asar...'
	cp "$claude_extract_dir/lib/net45/resources/app.asar" "$app_staging_dir/" || exit 1
	cp -a "$claude_extract_dir/lib/net45/resources/app.asar.unpacked" "$app_staging_dir/" || exit 1
	cd "$app_staging_dir" || exit 1
	"$asar_exec" extract app.asar app.asar.contents || exit 1

	# Frame fix wrapper
	echo 'Creating BrowserWindow frame fix wrapper...'
	local original_main
	original_main=$(node -e "const pkg = require('./app.asar.contents/package.json'); console.log(pkg.main);")
	echo "Original main entry: $original_main"

	cp "$source_dir/scripts/frame-fix-wrapper.js" app.asar.contents/frame-fix-wrapper.js || exit 1

	cat > app.asar.contents/frame-fix-entry.js << EOFENTRY
// Load frame fix first
require('./frame-fix-wrapper.js');
// Then load original main
require('./${original_main}');
EOFENTRY

	# BrowserWindow frame/titleBarStyle patching is handled at runtime by
	# frame-fix-wrapper.js via a Proxy on require('electron'). No sed patches
	# needed — the wrapper detects popup vs main windows by their options and
	# applies frame:true/false accordingly.

	# Update package.json
	echo 'Modifying package.json to load frame fix and add node-pty...'
	node -e "
const fs = require('fs');
const pkg = require('./app.asar.contents/package.json');
pkg.originalMain = pkg.main;
pkg.main = 'frame-fix-entry.js';
pkg.optionalDependencies = pkg.optionalDependencies || {};
pkg.optionalDependencies['node-pty'] = '^1.0.0';
fs.writeFileSync('./app.asar.contents/package.json', JSON.stringify(pkg, null, 2));
console.log('Updated package.json: main entry and node-pty dependency');
"

	# Create stub native module
	echo 'Creating stub native module...'
	mkdir -p app.asar.contents/node_modules/@ant/claude-native || exit 1
	cp "$source_dir/scripts/claude-native-stub.js" \
		app.asar.contents/node_modules/@ant/claude-native/index.js || exit 1

	mkdir -p app.asar.contents/resources/i18n || exit 1
	cp "$claude_extract_dir/lib/net45/resources/"*-*.json app.asar.contents/resources/i18n/ || exit 1

	# Copy tray icons into asar so both packaged (process.resourcesPath)
	# and unpackaged (app.getAppPath()) code paths can find them
	cp "$claude_extract_dir/lib/net45/resources/Tray"* app.asar.contents/resources/ 2>/dev/null || \
		echo 'Warning: No tray icon files found for asar inclusion'

	# Patch title bar detection
	patch_titlebar_detection

	# Extract electron module variable name for tray patches
	extract_electron_variable

	# Fix incorrect nativeTheme variable references
	fix_native_theme_references

	# Patch tray menu handler
	patch_tray_menu_handler

	# Patch tray icon selection
	patch_tray_icon_selection

	# Inject fast-path that updates the tray icon in place on theme
	# changes (avoids the KDE duplicate-SNI race on destroy+recreate)
	patch_tray_inplace_update

	# Patch menuBarEnabled to default to true when unset
	patch_menu_bar_default

	# Patch quick window
	patch_quick_window

	# Add Linux Claude Code support
	patch_linux_claude_code

	# Patch Cowork mode for Linux (TypeScript VM client + Unix socket)
	patch_cowork_linux

	# Copy cowork VM service daemon for Linux Cowork mode
	echo 'Installing cowork VM service daemon...'
	cp "$source_dir/scripts/cowork-vm-service.js" \
		app.asar.contents/cowork-vm-service.js || exit 1
	echo 'Cowork VM service daemon installed'
}
