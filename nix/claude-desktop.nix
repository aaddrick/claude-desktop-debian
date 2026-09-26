# Claude Desktop for Linux, repackaged from Anthropic's official .deb.
#
# Draft for the v3.0.0 official-deb rebase (ACQ-1); final shape is
# @typedrat's call. Design contract: docs/learnings/nix.md ("Target
# design for the rework"). nixpkgs precedent: discord, vscode — a
# vendor tarball/.deb unpacked and fixed up with autoPatchelfHook,
# keeping the vendored Chromium ELF (not run under a nixpkgs electron).
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
  addDriverRunpath,
  makeWrapper,
  asar,
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
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  nspr,
  nss,
  pango,
  systemd, # libudev.so.1
  # DT_NEEDED of the bundled virtiofsd helper
  libcap_ng,
  libseccomp,
  # dlopen'd by the Electron main process at runtime (not in DT_NEEDED).
  # runtimeDependencies lands these on the main ELF's runpath only:
  # autoPatchelf appends them to dynamic *executables*, not to the
  # co-located shared libs. That covers dlopens from the main process, but
  # the co-located ANGLE libs issue their own dlopen and need libGL on
  # every ELF's runpath instead (see appendRunpaths).
  libGL,
  libayatana-appindicator,
  libnotify,
  libpulseaudio,
  libsecret,
  libuuid, # in the official Depends (libuuid1); dlopen'd
  libxtst, # in the official Depends (libxtst6); dlopen'd
  pciutils,
  pipewire,
  wayland,
  # Absolute-path helpers the app spawns; see hostHelpers below.
  bash,
  procps,
  kdePackages,
  # Chrome import on KDE reads the key with kwallet-query; pulls in Qt.
  withKwallet ? false,
}:

let
  # Bumped automatically by .github/workflows/check-claude-version.yml;
  # mirrors OFFICIAL_DEB_VERSION in scripts/setup/official-deb.sh.
  version = "2.7032.0";

  poolBase = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop";

  # The official bundle spawns these host helpers by absolute path. NixOS
  # has no /usr/bin (only /usr/bin/env) and no /bin/bash, so each spawn
  # fails with ENOENT: Chrome import reports "Couldn't read Google
  # Chrome's key from your desktop keyring", and the agent toolset's
  # persistent shell never starts. postInstall rewrites the quoted JS
  # literals to store paths. The FHS env would also satisfy them, but it
  # runs the app under bwrap (NoNewPrivs, allowlisted /etc), which every
  # Claude Code session spawned by the app inherits: sudo refuses to run
  # and /etc/ssh, /etc/gitconfig etc. are missing.
  #
  # /usr/bin/kwallet-query is only needed for Chrome import on KDE and
  # pulls in Qt, so it is rewritten only with withKwallet = true. Not
  # rewritten: /usr/bin/update-desktop-database (only reached after reading
  # /usr/share/applications/com.anthropic.Claude.desktop, absent on NixOS).
  hostHelpers = {
    "/usr/bin/secret-tool" = "${libsecret}/bin/secret-tool";
    "/usr/bin/busctl" = "${systemd}/bin/busctl";
    "/bin/ps" = "${procps}/bin/ps";
    "/usr/bin/pgrep" = "${procps}/bin/pgrep";
    "/bin/bash" = "${bash}/bin/bash";
  }
  // lib.optionalAttrs withKwallet {
    "/usr/bin/kwallet-query" = "${kdePackages.kwallet}/bin/kwallet-query";
  };

  rewriteHelper = literal: target: ''
    files=$(grep -rlF --include='*.js' '"${literal}"' "$work/app" || true)
    if [[ -z $files ]]; then
      echo "claude-desktop: literal \"${literal}\" not found in app.asar" >&2
      exit 1
    fi
    for f in $files; do
      substituteInPlace "$f" --replace-fail '"${literal}"' '"${target}"'
      patched+=("$f")
    done
  '';

  # Chromium picks its secret store from XDG_CURRENT_DESKTOP: KWallet on
  # KDE, gnome-libsecret on the other desktops it recognises, and the
  # plaintext basic_text store everywhere else (niri, sway, Hyprland, ...),
  # even when a Secret Service is running. The app then logs
  # "isEncryptionAvailable=false ... session will not persist". Outside KDE
  # the flag therefore changes only that fallback; on KDE Chromium keeps
  # its own choice, so existing KWallet-encrypted data stays readable.
  # CLAUDE_PASSWORD_STORE overrides, as in the other launchers, and an
  # explicit --password-store on the command line comes later and wins.
  passwordStoreDefault = ''
    if [[ -n ''${CLAUDE_PASSWORD_STORE-} ]]; then
      set -- "--password-store=$CLAUDE_PASSWORD_STORE" "$@"
    elif [[ :''${XDG_CURRENT_DESKTOP-}: != *:KDE:* ]]; then
      set -- --password-store=gnome-libsecret "$@"
    fi
  '';

  # One url + one hash per arch block — the auto-bump range-seds from
  # each arch name to the next closing brace, so nothing else in this
  # file may put a hash assignment between an arch name and a closing
  # brace (see the header comment).
  srcs = {
    x86_64-linux = {
      url = "${poolBase}/claude-desktop_${version}_amd64.deb";
      hash = "sha256-Hn9FBLylsvay08QSPRRdcnZH538u4tBGhQcR5h59exE=";
    };
    aarch64-linux = {
      url = "${poolBase}/claude-desktop_${version}_arm64.deb";
      hash = "sha256-bcp5+kyLZSZ3gLVGDGJxWYUuLfoq0BHQOgSI978ibsM=";
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
    makeWrapper
    asar
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
    libx11
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxrandr
    libxcb
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
    libxtst # in the official Depends (libxtst6); dlopen'd
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
    #   share/applications, icons/  consumed by nix/fhs.nix's
    #                               extraInstallCommands
    # bin/claude-desktop is upstream's relative symlink into the tree; we
    # replace it with a makeWrapper script that execs the same in-tree
    # ELF (so /proc/self/exe still resolves inside this store path and
    # process.resourcesPath stays correct) while adding the NixOS Vulkan
    # ICD dir to the loader search. The official .desktop uses a
    # PATH-relative `Exec=claude-desktop %U`, so it resolves this wrapper
    # from a profile or from the FHS env without substitution.
    #
    # Chromium's co-located libvulkan.so.1 is the stock Khronos loader; it
    # searches the standard FHS ICD dirs, which are empty on NixOS, and
    # falls back to SwiftShader. A runpath edit can't fix this — the
    # loader keys on the env var and fixed filesystem paths, not
    # DT_RUNPATH — so VK_ADD_DRIVER_FILES is the only knob. It is additive
    # (prepended to, not replacing, the normal search) and thus
    # dangling-safe: a missing dir or a user's own setting still wins. The
    # value leaking into the MCP servers the app spawns is harmless —
    # they are CLI processes that never init Vulkan, and the ICD dir is
    # the correct one for any that did.
    mkdir -p $out
    cp -a usr/lib usr/share $out/
    makeWrapper $out/lib/claude-desktop/claude-desktop \
      $out/bin/claude-desktop \
      --prefix VK_ADD_DRIVER_FILES : \
        "${addDriverRunpath.driverLink}/share/vulkan/icd.d" \
      --run ${lib.escapeShellArg passwordStoreDefault}

    runHook postInstall
  '';

  # Rewrite hostHelpers inside app.asar and repack it. Runs before
  # fixup, so autoPatchelf still sees the final tree.
  #
  #   - A missing literal fails the build rather than silently shipping
  #     a stale path after an upstream re-minification.
  #   - The bundled V8 code cache (compile-cache/*.jsc) is dropped for
  #     every patched file: V8 accepts a cache for an edit that keeps the
  #     source length and would run the unpatched code.
  #   - asar pack matches --unpack against the crawled path, so the glob
  #     is built from absolute paths under the extraction root. It packs
  #     into a fresh directory because pack never clears a stale
  #     app.asar.unpacked; the unpacked set is then compared by content
  #     and by the new header.
  #   - asar extract writes unpacked files 0644; restore the official
  #     modes (github-mcp-server and the .node bindings are executable).
  postInstall = ''
    resources=$out/lib/claude-desktop/resources
    work=$(mktemp -d)
    patched=()

    asar extract "$resources/app.asar" "$work/app"

    ${lib.concatStrings (lib.mapAttrsToList rewriteHelper hostHelpers)}

    for f in "''${patched[@]}"; do
      rm -f "$work/app/compile-cache/$(basename "$f")".*.jsc
    done

    (cd "$resources/app.asar.unpacked" && find . -type f | sort) \
      > "$work/unpacked"
    unpack="{$(sed "s|^\./|$work/app/|" "$work/unpacked" | paste -sd,)}"
    mkdir "$work/out"
    asar pack "$work/app" "$work/out/app.asar" --unpack "$unpack"

    diff -r "$resources/app.asar.unpacked" "$work/out/app.asar.unpacked"
    asar list --is-pack "$work/out/app.asar" \
      | sed -n 's|^unpack *: /|./|p' | sort | diff "$work/unpacked" -
    while read -r f; do
      chmod --reference="$resources/app.asar.unpacked/$f" \
        "$work/out/app.asar.unpacked/$f"
    done < "$work/unpacked"

    rm -r "$resources/app.asar" "$resources/app.asar.unpacked"
    mv "$work/out/app.asar" "$work/out/app.asar.unpacked" "$resources/"
    rm -r "$work"
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

  # Chromium's bundled ANGLE (the co-located libEGL.so/libGLESv2.so)
  # dlopen()s the glvnd dispatcher libEGL.so.1 by bare soname at
  # GPU-init time; glvnd then self-locates the host GL driver under
  # ${addDriverRunpath.driverLink}. A dlopen resolves against the
  # *calling* object's runpath, and the co-located libs carry only their
  # own DT_NEEDED there — not libGL — so the dispatcher is unfindable and
  # the GPU process fails EGL init and crash-loops. appendRunpaths adds
  # these to every patched ELF's runpath (runtimeDependencies would not:
  # autoPatchelf applies those to executables only, missing the .so that
  # issues the dlopen). Runpath, not a LD_LIBRARY_PATH wrapper, so the
  # driver libs don't leak into the env of the MCP servers the app spawns.
  # (Chromium's bundled Vulkan loader can't be reached this way — it keys
  # on the env var, not runpath — so it's handled by the
  # VK_ADD_DRIVER_FILES wrapper in installPhase.)
  appendRunpaths = [
    "${lib.getLib libGL}/lib"
    "${addDriverRunpath.driverLink}/lib"
  ];

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
