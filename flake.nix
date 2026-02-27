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
        node-pty = pkgs.callPackage ./nix/node-pty.nix { };
        claude-desktop = pkgs.callPackage ./nix/claude-desktop.nix {
          inherit node-pty;
        };
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
        overlays.default = final: prev: let
          node-pty = final.callPackage ./nix/node-pty.nix { };
        in {
          claude-desktop = final.callPackage ./nix/claude-desktop.nix {
            inherit node-pty;
          };
          claude-desktop-fhs = final.callPackage ./nix/fhs.nix {
            claude-desktop = final.claude-desktop;
          };
        };
      };
    };
}
