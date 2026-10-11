{
  inputs,
  lib,
  pkgs,
}:
let
  evaluated = lib.nixosSystem {
    specialArgs = { inherit inputs; };
    modules = [
      (import ../../nixos-modules { inherit inputs lib; })
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        nixpkgs.overlays = [ (import ../../overlays inputs).default ];
        system.stateVersion = "24.05";

        dev.johnrinehart.programs.git.meld.enable = true;
      }
    ];
  };
  cfg = evaluated.config;
  package = evaluated.pkgs.dev.johnrinehart.git-meld;
in
assert builtins.elem package cfg.environment.systemPackages;
assert lib.getExe' package "git-meld" == "${package}/bin/git-meld";
pkgs.runCommand "git-meld-module-evaluation" { } ''
  touch $out
''
