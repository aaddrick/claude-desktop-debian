{
  description = "Claude Desktop for Linux";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" ];

      perSystem = { pkgs, ... }: let
        claude-desktop = pkgs.callPackage ./nix/claude-desktop.nix { };
      in {
        packages = {
          inherit claude-desktop;
          claude-desktop-fhs = pkgs.callPackage ./nix/fhs.nix {
            inherit claude-desktop;
          };
          default = claude-desktop;
        };
      };

      flake = {
        overlays.default = final: prev: {
          claude-desktop = final.callPackage ./nix/claude-desktop.nix { };
          claude-desktop-fhs = final.callPackage ./nix/fhs.nix {
            claude-desktop = final.claude-desktop;
          };
        };
      };
    };
}
