{
  lib,
  stdenvNoCC,
  fetchurl,
  electron,
  p7zip,
  icoutils,
  imagemagick,
  nodejs,
  nodePackages,
  makeDesktopItem,
  makeWrapper,
  python3,
  bash,
  getent,
}:
let
  pname = "claude-desktop";
  version = "1.1.4328";

  srcs = {
    x86_64-linux = fetchurl {
      url = "https://downloads.claude.ai/releases/win32/x64/${version}/Claude-d8e39139e1c50f5530ac3da3af80e689710c8ea1.exe";
      hash = "sha256-ngFY1mYwBIZLOYD5I7Lz/v5OexUKNe4MUHcq8VOejI4=";
    };
    aarch64-linux = fetchurl {
      url = "https://downloads.claude.ai/releases/win32/arm64/${version}/Claude-d8e39139e1c50f5530ac3da3af80e689710c8ea1.exe";
      hash = "sha256-PvKw6JpfLIhzbcrfogLltHNKyZfJtHOpOrGb+vcOkSM=";
    };
  };

  src = srcs.${stdenvNoCC.hostPlatform.system} or (throw "Unsupported system: ${stdenvNoCC.hostPlatform.system}");

  sourceRoot = ./..;

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
    nodePackages.asar
    icoutils
    imagemagick
    makeWrapper
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
      --build nix \
      --clean no

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # Install app.asar and unpacked resources
    mkdir -p $out/lib/claude-desktop/resources
    cp build/electron-app/app.asar $out/lib/claude-desktop/resources/
    cp -r build/electron-app/app.asar.unpacked $out/lib/claude-desktop/resources/

    # TODO: node-pty is not in nixpkgs; terminal features (Claude Code)
    # require it. A future improvement could build it with buildNpmPackage.

    # Install icons
    for size in 16 24 32 48 64 256; do
      icon_dir=$out/share/icons/hicolor/"$size"x"$size"/apps
      mkdir -p "$icon_dir"
      icon=$(find build/ -name "claude_*''${size}x''${size}x32.png" 2>/dev/null | head -1)
      if [ -n "$icon" ]; then
        install -Dm644 "$icon" "$icon_dir/claude-desktop.png"
      fi
    done

    # Install tray icons into resources
    for tray_icon in build/electron-app/node_modules/electron/dist/resources/Tray*; do
      if [ -f "$tray_icon" ]; then
        cp "$tray_icon" $out/lib/claude-desktop/resources/
      fi
    done

    # Install .desktop file
    mkdir -p $out/share/applications
    install -Dm644 ${desktopItem}/share/applications/* $out/share/applications/

    # Create wrapper script
    mkdir -p $out/bin
    makeWrapper ${electron}/bin/electron $out/bin/claude-desktop \
      --add-flags "$out/lib/claude-desktop/resources/app.asar" \
      --add-flags "--disable-features=CustomTitlebar" \
      --add-flags "\''${NIXOS_OZONE_WL:+\''${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations}}"

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
