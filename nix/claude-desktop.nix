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
  node-pty,
}:
let
  pname = "claude-desktop";
  version = "1.1.6679";

  srcs = {
    x86_64-linux = fetchurl {
      url = "https://downloads.claude.ai/releases/win32/x64/1.1.6679/Claude-f8f4ffd55f41cdea65b2c8adb312eb985aef916f.exe";
      hash = "sha256-GsSnbIPKFcOlmbfRT9P/0KXooDyXfmHxikiR5kAr5hE=";
    };
    aarch64-linux = fetchurl {
      url = "https://downloads.claude.ai/releases/win32/arm64/1.1.6679/Claude-f8f4ffd55f41cdea65b2c8adb312eb985aef916f.exe";
      hash = "sha256-chXouKI/IlXMLzXukhXTkW39uFThiuV/uxJ0b7LFntc=";
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
      --node-pty-dir "${node-pty}/lib/node_modules/node-pty" \
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
    for tray_icon in build/electron-app/nix-resources/Tray*; do
      if [ -f "$tray_icon" ]; then
        cp "$tray_icon" $out/lib/claude-desktop/resources/
      fi
    done

    # Install SSH helpers into resources
    if [ -d build/electron-app/nix-resources/claude-ssh ]; then
      cp -r build/electron-app/nix-resources/claude-ssh $out/lib/claude-desktop/resources/
    fi

    # Install locale JSON files into resources (belt-and-suspenders;
    # they're also packed inside app.asar at resources/i18n/)
    for locale_json in build/claude-extract/lib/net45/resources/*-*.json; do
      if [ -f "$locale_json" ]; then
        cp "$locale_json" $out/lib/claude-desktop/resources/
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
