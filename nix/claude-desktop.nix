# Pending rewrite for the v3.0.0 official-deb rebase (owner @typedrat).
#
# The Windows-installer derivation this file used to contain (7z-extract
# the exe, stock nixpkgs Electron, co-located resources tree, node-pty
# build) was deleted with the acquisition swap — recover it from git
# history if needed: `git log --oneline -- nix/claude-desktop.nix`.
#
# Target design per the rebase plan and
# docs/learnings/official-deb-rebase-verification.md:
#   - fetchurl the official .deb (SRI hash from the APT Packages index)
#   - unpack and autoPatchelfHook the official tree (nixpkgs precedent:
#     signal-desktop, slack); no resourcesPath hack — the official tree
#     is already co-located
#   - keep buildFHSEnv (nix/fhs.nix) as the default output; the FHS env
#     must bind-provide OVMF at /usr/share/OVMF/OVMF_CODE{_4M,}.fd for
#     Cowork (the official firmware probe list is hardcoded)
{ lib }:
throw ''
  claude-desktop: the Nix derivation is pending its official-deb rebase
  rework (v3.0.0 branch, @typedrat spike). Build from the last
  Windows-pipeline commit for a working derivation:
      git log --oneline -- nix/claude-desktop.nix
''
