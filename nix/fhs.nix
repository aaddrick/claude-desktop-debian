{
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
}:

let
  # Cowork's firmware probe list is hardcoded in the official bundle
  # with no env override
  # (docs/learnings/official-deb-rebase-verification.md):
  #   x86_64  -> /usr/share/OVMF/OVMF_CODE_4M.fd, /usr/share/OVMF/OVMF_CODE.fd
  #   aarch64 -> /usr/share/AAVMF/AAVMF_CODE.fd
  # nixpkgs' OVMF puts firmware at ${OVMF.fd}/FV/*.fd — nothing under
  # share/ — so adding OVMF itself to targetPkgs never lands a file at
  # the probed path. This shim exposes the firmware under share/, which
  # buildFHSEnv links into /usr/share inside the env. Same gap the RPM
  # closes with %post compat symlinks (CW-1).
  #
  # Confidence notes for @typedrat:
  #   - x86_64: nixpkgs builds a single 4M-sized OVMF_CODE.fd, so both
  #     Debian-flavored names alias the same file. Verified shape.
  #   - aarch64: recent nixpkgs OVMF ships FV/AAVMF_CODE.fd (padded for
  #     QEMU pflash); older ones only QEMU_EFI.fd — the fallback branch
  #     covers that. Unverified on real aarch64.
  ovmfCompat = runCommand "claude-desktop-ovmf-compat" { } (
    if stdenv.hostPlatform.isx86_64 then
      ''
        mkdir -p $out/share/OVMF
        ln -s ${OVMF.fd}/FV/OVMF_CODE.fd $out/share/OVMF/OVMF_CODE.fd
        ln -s ${OVMF.fd}/FV/OVMF_CODE.fd $out/share/OVMF/OVMF_CODE_4M.fd
      ''
    else
      ''
        mkdir -p $out/share/AAVMF
        if [[ -e ${OVMF.fd}/FV/AAVMF_CODE.fd ]]; then
          ln -s ${OVMF.fd}/FV/AAVMF_CODE.fd $out/share/AAVMF/AAVMF_CODE.fd
        else
          ln -s ${OVMF.fd}/FV/QEMU_EFI.fd $out/share/AAVMF/AAVMF_CODE.fd
        fi
      ''
  );
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
