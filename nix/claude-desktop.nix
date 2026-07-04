# Claude Desktop for Linux, repackaged from Anthropic's official .deb.
#
# Draft for the v3.0.0 official-deb rebase (ACQ-1); final shape is
# @typedrat's call. Design contract: docs/learnings/nix.md ("Target
# design for the rework"). nixpkgs precedent: signal-desktop, slack —
# vendor .deb unpacked with dpkg and fixed up with autoPatchelfHook.
#
# Load-bearing invariants:
#
#   - The official tree is bare co-located (usr/lib/claude-desktop/
#     {claude-desktop, chrome-sandbox, resources/}). We copy that tree
#     whole — the ELF is a real file, never a symlink — so
#     /proc/self/exe resolves inside this store path and
#     process.resourcesPath is correct by construction. No nixpkgs
#     electron, no resourcesPath hack; docs/learnings/nix.md explains
#     why that must not return.
#
#   - check-claude-version auto-bumps this file with anchored seds
#     (docs/learnings/nix.md, "The SRI auto-bump contract"): it rewrites
#     the version line and range-seds each arch block's SRI hash. Keep
#     exactly one version assignment in this file and exactly one hash
#     assignment inside each arch block, and never write the literal
#     tokens the seds anchor on (version/hash followed by ` = "`)
#     anywhere else — not even in a comment, or the bump corrupts it.
#     The urls must derive from the version by interpolation so a bump
#     keeps them in sync.
{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  # DT_NEEDED of the main Electron ELF (objdump -p on 1.18286.0)
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  glib,
  gtk3,
  libgbm,
  libxkbcommon,
  nspr,
  nss,
  pango,
  systemd, # libudev.so.1
  xorg,
  # DT_NEEDED of the bundled virtiofsd helper
  libcap_ng,
  libseccomp,
  # dlopen'd by Chromium/Electron at runtime (not in DT_NEEDED, so
  # autoPatchelf can't see them; appended to every ELF's runpath via
  # runtimeDependencies — same approach as nixpkgs' signal-desktop)
  libGL,
  libayatana-appindicator,
  libnotify,
  libpulseaudio,
  libsecret,
  libuuid, # in the official Depends (libuuid1); dlopen'd
  pciutils,
  pipewire,
  wayland,
}:

let
  # Bumped automatically by .github/workflows/check-claude-version.yml;
  # mirrors OFFICIAL_DEB_VERSION in scripts/setup/official-deb.sh.
  version = "1.18286.0";

  poolBase = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop";

  # One url + one hash per arch block — the auto-bump range-seds from
  # each arch name to the next closing brace, so nothing else in this
  # file may put a hash assignment between an arch name and a closing
  # brace (see the header comment).
  srcs = {
    x86_64-linux = {
      url = "${poolBase}/claude-desktop_${version}_amd64.deb";
      hash = "sha256-jzFK0agKq1JxGo6qvAaq5I+zQfCt6koNcmTbXKudBTY=";
    };
    aarch64-linux = {
      url = "${poolBase}/claude-desktop_${version}_arm64.deb";
      hash = "sha256-SCC5iankMzlWtsvq7icy3StJkE+6VAtHKWPIADyAhsc=";
    };
  };
in
stdenv.mkDerivation {
  pname = "claude-desktop";
  inherit version;

  src = fetchurl (
    srcs.${stdenv.hostPlatform.system}
      or (throw "claude-desktop: unsupported system ${stdenv.hostPlatform.system}")
  );

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    glib
    gtk3
    libcap_ng
    libgbm
    libseccomp
    libxkbcommon
    nspr
    nss
    pango
    stdenv.cc.cc.lib # libstdc++ (node-pty), libgcc_s
    systemd
    xorg.libX11
    xorg.libXcomposite
    xorg.libXdamage
    xorg.libXext
    xorg.libXfixes
    xorg.libXrandr
    xorg.libxcb
  ];

  runtimeDependencies = map lib.getLib [
    libGL
    libayatana-appindicator
    libnotify
    libpulseaudio
    libsecret
    libuuid
    pciutils
    pipewire
    systemd
    wayland
    xorg.libXtst # in the official Depends (libxtst6); dlopen'd
  ];

  # Not `dpkg-deb -x`: chrome-sandbox is recorded SUID (rwsr-xr-x) in
  # data.tar and tar's mode-restore fails inside the build sandbox.
  # --no-same-permissions applies the umask instead, dropping the SUID
  # bit that the store couldn't represent anyway (see the sandbox note
  # below).
  unpackPhase = ''
    runHook preUnpack
    dpkg-deb --fsys-tarfile "$src" \
      | tar -x --no-same-owner --no-same-permissions
    runHook postUnpack
  '';

  dontConfigure = true;
  dontBuild = true;

  # The bundled ELFs are already stripped upstream; re-stripping a
  # 200 MB Electron binary is slow and buys nothing.
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    # Ship the official install tree as-is:
    #   lib/claude-desktop/…        bare co-located app tree
    #   bin/claude-desktop          upstream's relative symlink into it
    #                               (…/exe still resolves in-tree; the
    #                               kernel follows the link to the real
    #                               ELF inside this store path)
    #   share/applications, icons/  consumed by nix/fhs.nix's
    #                               extraInstallCommands
    # The official .desktop already uses a PATH-relative
    # `Exec=claude-desktop %U`, so it works from a profile or from the
    # FHS wrapper without substitution.
    mkdir -p $out
    cp -a usr/lib usr/share usr/bin $out/

    runHook postInstall
  '';

  # chrome-sandbox ships SUID in the official .deb, but the Nix store
  # cannot carry SUID bits. On kernels with unprivileged user namespaces
  # enabled (the NixOS default), Chromium prefers the namespace sandbox
  # and never invokes the SUID helper, so we ship it 0755 and do NOT
  # weaken sandboxing with --no-sandbox anywhere. Same stance as
  # nixpkgs' signal-desktop/slack. Kernels with userns disabled will
  # fail with Chromium's sandbox error; that is a host policy decision.
  #
  # autoPatchelf resolves the bundled co-located libs (libffmpeg.so,
  # libEGL.so, libGLESv2.so, libvk_swiftshader.so, libvulkan.so.1) from
  # the output tree itself; the explicit search path is belt and braces
  # since the ELF's upstream RPATH is `$ORIGIN`.
  #
  # cowork-linux-helper (coworkd) is static Go — autoPatchelf skips it.
  # virtiofsd and chrome-native-host are glibc >= 2.34 (fine on any
  # current nixpkgs) and their DT_NEEDED are covered by buildInputs.
  preFixup = ''
    addAutoPatchelfSearchPath "$out/lib/claude-desktop"
  '';

  meta = {
    description = "Claude Desktop for Linux (repackaged official .deb)";
    homepage = "https://claude.ai";
    downloadPage = "https://downloads.claude.ai/claude-desktop/apt/stable";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    # Derived from srcs so the arch literals stay out of meta — the
    # auto-bump's range seds anchor on those strings (see header).
    platforms = builtins.attrNames srcs;
    mainProgram = "claude-desktop";
  };
}
