{
  lib,
  stdenv,
  runCommand,
  buildFHSEnv,
  bubblewrap,
  claude-desktop,
  nodejs,
  docker,
  docker-compose,
  openssl,
  glibc,
  uv,
  OVMF,
  qemu_kvm,
  virtiofsd,
}:

let
  # Cowork's firmware probe list is hardcoded in the official bundle
  # with no env override
  # (docs/learnings/official-deb-rebase-verification.md):
  #   x86_64  -> /usr/share/OVMF/OVMF_CODE_4M.fd, /usr/share/OVMF/OVMF_CODE.fd
  #   aarch64 -> /usr/share/AAVMF/AAVMF_CODE.fd
  # It then derives the *writable* VARS template beside the CODE file it
  # found by renaming OVMF_CODE -> OVMF_VARS / AAVMF_CODE -> AAVMF_VARS,
  # and copies it per VM to seed efivars; coworkd aborts with "no EFI
  # variable-store template configured" if that sibling is absent. So the
  # shim must expose the matched CODE+VARS pair, not just CODE. (deb/rpm
  # get away with a CODE-only symlink because the distro's edk2 package
  # already drops OVMF_VARS beside it; on the Nix FHS this shim is the
  # only source — same gap the RPM closes for CODE with CW-1.)
  #
  # nixpkgs' OVMF lands firmware at ${OVMF.fd}/FV/*.fd — nothing under
  # share/ — so a bare OVMF in targetPkgs never hits the probe; symlink
  # the FV/ files into share/, which buildFHSEnv maps to /usr/share.
  # x86_64 aliases both Debian CODE names (and both VARS names) onto the
  # single 4M-sized nixpkgs build. The build fails loudly if a source is
  # gone rather than ship a dangling symlink that only bites at VM boot.
  ovmfCompat =
    let
      link = src: dst: ''
        [[ -e ${OVMF.fd}/FV/${src} ]] || {
          echo "ovmfCompat: ${OVMF.fd}/FV/${src} missing; OVMF layout changed" >&2
          exit 1
        }
        mkdir -p "$(dirname "$out/share/${dst}")"
        ln -s ${OVMF.fd}/FV/${src} "$out/share/${dst}"
      '';
      pairs =
        if stdenv.hostPlatform.isx86_64 then
          [
            (link "OVMF_CODE.fd" "OVMF/OVMF_CODE.fd")
            (link "OVMF_CODE.fd" "OVMF/OVMF_CODE_4M.fd")
            (link "OVMF_VARS.fd" "OVMF/OVMF_VARS.fd")
            (link "OVMF_VARS.fd" "OVMF/OVMF_VARS_4M.fd")
          ]
        else
          [
            (link "AAVMF_CODE.fd" "AAVMF/AAVMF_CODE.fd")
            (link "AAVMF_VARS.fd" "AAVMF/AAVMF_VARS.fd")
          ];
    in
    runCommand "claude-desktop-ovmf-compat" { } (lib.concatStrings pairs);
in
buildFHSEnv {
  name = "claude-desktop";

  # Cowork gates VM boot on BOTH a firmwarePath (the ovmfCompat shim
  # above) and a qemuPath — it searches PATH for qemu-system-x86_64 /
  # qemu-system-aarch64, and coworkd launches a real accel=kvm guest
  # (pflash OVMF, vhost-vsock, virtiofsd --shared-dir). qemu_kvm is the
  # host-cpu-only build, so it ships exactly that arch's binary (~1.5 GB
  # closure vs 2.1 GB for the all-targets qemu). /dev/kvm and
  # /dev/vhost-vsock are reachable inside the env — buildFHSEnv binds the
  # whole /dev (--dev-bind /dev /dev) — but the host must still grant
  # kvm-group access (/dev/kvm is root:kvm 0660, else EACCES) and load
  # vhost_vsock (no node until the module is in); --doctor flags both.
  #
  # virtiofsd is a THIRD gate, and the one #806 hit. Cowork probes
  # /usr/libexec/virtiofsd then /usr/bin/virtiofsd (R_OK), and only falls
  # back to its own resources/virtiofsd when the host is Ubuntu 22 —
  # `return probed || (isUbuntu22 ? bundled : null)`. #773 un-gated that
  # fallback via patch_virtiofsd_probe, but nix/claude-desktop.nix unpacks
  # the official .deb without running scripts/patches/*.sh, so no asar
  # patch reaches this format. With the probe unresolved, Cowork reports
  # virtualization_tools_missing ("Cowork requires QEMU") on every non-
  # Ubuntu-22 host, NixOS included. nixpkgs' virtiofsd is the Rust
  # implementation at bin/virtiofsd, which buildFHSEnv surfaces at
  # /usr/bin/virtiofsd — the second probe path — so the package resolves
  # the gate without widening the probe array.
  targetPkgs = pkgs: [
    bubblewrap
    claude-desktop
    docker
    docker-compose
    glibc
    nodejs
    openssl
    ovmfCompat
    qemu_kvm
    uv
    virtiofsd
  ];

  runScript = "${claude-desktop}/bin/claude-desktop";

  extraInstallCommands = ''
    # Copy desktop file
    mkdir -p $out/share/applications
    cp ${claude-desktop}/share/applications/* $out/share/applications/

    # Copy icons
    mkdir -p $out/share/icons
    cp -r ${claude-desktop}/share/icons/* $out/share/icons/
  '';

  meta = claude-desktop.meta // {
    description = "Claude Desktop for Linux (FHS environment for MCP servers)";
  };
}
