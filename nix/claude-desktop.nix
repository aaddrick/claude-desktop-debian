{
  lib,
  stdenvNoCC,
  fetchurl,
  electron,
  p7zip,
  icoutils,
  imagemagick,
  nodejs,
  asar,
  makeDesktopItem,
  python3,
  bash,
  getent,
  node-pty,
}:
let
  pname = "claude-desktop";
  version = "1.3883.0";

  srcs = {
    x86_64-linux = fetchurl {
      url = "https://downloads.claude.ai/releases/win32/x64/1.3883.0/Claude-93ff6cb984386882b4bd9b6bca80d4cf5af8e13b.exe";
      hash = "sha256-E/pT3eoKNi5LkdKJx+nxGGA5t5ljtajjFAnjHKwbtZE=";
    };
    aarch64-linux = fetchurl {
      url = "https://downloads.claude.ai/releases/win32/arm64/1.3883.0/Claude-93ff6cb984386882b4bd9b6bca80d4cf5af8e13b.exe";
      hash = "sha256-SGK3aE0cFCB5IsSIZPZE03ZgJgEiZfW8YhEf9IyuyYI=";
    };
  };

  src = srcs.${stdenvNoCC.hostPlatform.system} or (throw "Unsupported system: ${stdenvNoCC.hostPlatform.system}");

  sourceRoot = lib.cleanSourceWith {
    src = ./..;
    filter = path: type:
      let rel = lib.removePrefix (toString ./.. + "/") path;
      in !(lib.hasPrefix "build-reference" rel)
      && !(lib.hasPrefix "logs" rel)
      && !(lib.hasPrefix "test-build" rel)
      && !(lib.hasPrefix "squashfs-root" rel)
      && !(lib.hasPrefix "result" rel);
  };

  # The unwrapped electron derivation — contains the real ELF binary
  # and Chromium resources (.pak files, locales/, etc.).
  electronUnwrapped = electron.passthru.unwrapped or electron;
  electronDir = "${electronUnwrapped}/libexec/electron";

  desktopItem = makeDesktopItem {
    name = "claude-desktop";
    exec = "claude-desktop %u";
    icon = "claude-desktop";
    type = "Application";
    terminal = false;
    desktopName = "Claude";
    genericName = "Claude Desktop";
    startupWMClass = "Claude";
    categories = [ "Office" "Utility" ];
    mimeTypes = [ "x-scheme-handler/claude" ];
  };
in
stdenvNoCC.mkDerivation {
  inherit pname version src;

  nativeBuildInputs = [
    p7zip
    nodejs
    asar
    icoutils
    imagemagick
    bash
    python3
    getent
  ];

  # The exe is not a standard archive — use manual unpack
  dontUnpack = true;

  buildPhase = ''
    runHook preBuild

    export HOME=$TMPDIR

    # Copy exe to a writable location for build.sh
    cp $src Claude-Setup.exe

    # Run build.sh in nix mode — it handles extraction, patching, icon
    # extraction, and asar repacking. --source-dir points at the repo
    # root so build.sh can find scripts/.
    bash ${sourceRoot}/build.sh \
      --exe "$(pwd)/Claude-Setup.exe" \
      --source-dir "${sourceRoot}" \
      --node-pty-dir "${node-pty}/lib/node_modules/node-pty" \
      --build nix \
      --clean no

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    #==========================================================================
    # Create a custom Electron tree with app resources co-located.
    #
    # On NixOS, the stock electron-unwrapped lives in a read-only store
    # path.  Chromium computes process.resourcesPath from /proc/self/exe,
    # so it always points to electron-unwrapped's resources/ dir — which
    # doesn't contain the app's locale JSONs, tray icons, etc.  When
    # ELECTRON_FORCE_IS_PACKAGED=true, the app reads en-US.json from
    # resourcesPath at module load time (before frame-fix-wrapper.js can
    # correct the path), causing an ENOENT crash.
    #
    # Solution: copy the Electron ELF binary into our own tree so that
    # /proc/self/exe resolves here, then merge both Electron's and the
    # app's resources into resources/.  Everything else (shared libs,
    # .pak files, locales/) is symlinked to avoid duplication.
    #==========================================================================
    electron_tree=$out/lib/claude-desktop/electron

    mkdir -p $electron_tree/resources

    # Copy the ELF binary — MUST be a real copy (not symlink) so that
    # /proc/self/exe resolves to our tree
    cp ${electronDir}/electron $electron_tree/electron

    # Symlink everything else from electron-unwrapped
    for item in ${electronDir}/*; do
      name=$(basename "$item")
      [[ "$name" = "electron" ]] && continue
      [[ "$name" = "resources" ]] && continue
      ln -s "$item" "$electron_tree/$name"
    done

    # Populate resources/ — start with Electron's own (default_app.asar)
    for item in ${electronDir}/resources/*; do
      ln -s "$item" "$electron_tree/resources/$(basename "$item")"
    done

    # Install app.asar and unpacked resources into the merged tree
    cp build/electron-app/app.asar $electron_tree/resources/
    cp -r build/electron-app/app.asar.unpacked $electron_tree/resources/

    # Install tray icons into resources
    for tray_icon in build/electron-app/nix-resources/Tray*; do
      [[ -f "$tray_icon" ]] && cp "$tray_icon" $electron_tree/resources/
    done

    # Install SSH helpers into resources
    if [[ -d build/electron-app/nix-resources/claude-ssh ]]; then
      cp -r build/electron-app/nix-resources/claude-ssh \
        $electron_tree/resources/
    fi

    # Install cowork resources (smol-bin, plugin shim)
    for cowork_res in build/electron-app/nix-resources/smol-bin.*.vhdx \
                      build/electron-app/nix-resources/cowork-plugin-shim.sh; do
      if [[ -f "$cowork_res" ]]; then
        cp "$cowork_res" $electron_tree/resources/
        echo "Installed cowork resource: $(basename "$cowork_res")"
      fi
    done

    # Install ion-dist static assets (app:// protocol handler root for
    # Third-Party Inference setup — see issue #488)
    if [[ -d build/electron-app/nix-resources/ion-dist ]]; then
      cp -r build/electron-app/nix-resources/ion-dist \
        $electron_tree/resources/
      echo "Installed cowork resource: ion-dist"
    fi

    # Install locale JSON files into resources
    for locale_json in build/claude-extract/lib/net45/resources/*-*.json; do
      [[ -f "$locale_json" ]] \
        && cp "$locale_json" $electron_tree/resources/
    done

    # Create the electron wrapper — replicates the env setup from the
    # stock electron wrapper (GIO, GTK, GDK_PIXBUF, XDG_DATA_DIRS) but
    # execs our custom binary.  We extract everything except the final
    # exec line from the stock wrapper, then append our own exec.
    head -n -1 ${electron}/bin/electron > $electron_tree/electron-wrapper
    echo "exec \"$electron_tree/electron\" \"\$@\"" >> $electron_tree/electron-wrapper
    chmod +x $electron_tree/electron-wrapper

    # Update CHROME_DEVEL_SANDBOX to point to our tree's chrome-sandbox
    substituteInPlace $electron_tree/electron-wrapper \
      --replace-quiet "${electron}/libexec/electron/chrome-sandbox" \
        "$electron_tree/chrome-sandbox"

    #==========================================================================
    # Standard install (icons, desktop file, launcher)
    #==========================================================================

    # Convenience symlink for resources dir (used by launcher, FHS, etc.)
    ln -s $electron_tree/resources $out/lib/claude-desktop/resources

    # Install icons
    for size in 16 24 32 48 64 256; do
      icon_dir=$out/share/icons/hicolor/"$size"x"$size"/apps
      mkdir -p "$icon_dir"
      icon=$(find build/ -name "claude_*''${size}x''${size}x32.png" 2>/dev/null | head -1)
      if [[ -n "$icon" ]]; then
        install -Dm644 "$icon" "$icon_dir/claude-desktop.png"
      fi
    done

    # Install shared launcher library + doctor (launcher-common.sh
    # sources doctor.sh at runtime, so both must live in the same dir)
    install -Dm755 ${sourceRoot}/scripts/launcher-common.sh \
      $out/lib/claude-desktop/launcher-common.sh
    install -Dm755 ${sourceRoot}/scripts/doctor.sh \
      $out/lib/claude-desktop/doctor.sh

    # Install .desktop file
    mkdir -p $out/share/applications
    install -Dm644 ${desktopItem}/share/applications/* $out/share/applications/

    # Create launcher script
    mkdir -p $out/bin
    cat > $out/bin/claude-desktop <<'LAUNCHER'
#!/usr/bin/env bash
# Claude Desktop launcher for NixOS

electron_exec="ELECTRON_PLACEHOLDER"
app_path="RESOURCES_PLACEHOLDER/app.asar"

source "LAUNCHER_LIB_PLACEHOLDER"

# Handle --doctor flag before anything else
if [[ "''${1:-}" == '--doctor' ]]; then
	run_doctor "$electron_exec"
	exit $?
fi

# Setup logging and environment
setup_logging || exit 1
setup_electron_env
cleanup_orphaned_cowork_daemon
cleanup_stale_lock
cleanup_stale_cowork_socket

# Log startup info
log_message '--- Claude Desktop Launcher Start (NixOS) ---'
log_message "Timestamp: $(date)"
log_message "Arguments: $@"

# Check for display
if ! check_display; then
	log_message 'No display detected (TTY session)'
	echo 'Error: Claude Desktop requires a graphical desktop environment.' >&2
	echo 'Please run from within an X11 or Wayland session, not from a TTY.' >&2
	exit 1
fi

# Detect display backend (handles CLAUDE_USE_WAYLAND)
detect_display_backend

# Build Electron arguments
build_electron_args 'nix'

# Add app path
electron_args+=("$app_path")

# Execute Electron
log_message "Executing: $electron_exec ''${electron_args[*]} $*"
"$electron_exec" "''${electron_args[@]}" "$@" >> "$log_file" 2>&1
exit_code=$?
log_message "Electron exited with code: $exit_code"
exit $exit_code
LAUNCHER
    # Substitute placeholders — electron_exec points to our custom
    # wrapper (which sets GTK/GIO env then execs our merged binary)
    substituteInPlace $out/bin/claude-desktop \
      --replace-fail "ELECTRON_PLACEHOLDER" "$electron_tree/electron-wrapper" \
      --replace-fail "RESOURCES_PLACEHOLDER" "$electron_tree/resources" \
      --replace-fail "LAUNCHER_LIB_PLACEHOLDER" "$out/lib/claude-desktop/launcher-common.sh"
    chmod +x $out/bin/claude-desktop

    runHook postInstall
  '';

  meta = with lib; {
    description = "Claude Desktop for Linux";
    homepage = "https://github.com/aaddrick/claude-desktop-debian";
    license = licenses.unfree;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    mainProgram = "claude-desktop";
  };
}
