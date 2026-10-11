{
  inputs,
  lib,
  pkgs,
}:
let
  mkSystem =
    extraModule:
    lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        (import ../../nixos-modules { inherit inputs lib; })
        {
          nixpkgs.hostPlatform = "x86_64-linux";
          nixpkgs.overlays = [ (import ../../overlays inputs).default ];
          system.stateVersion = "24.05";
        }
        extraModule
      ];
    };

  server = mkSystem { };
  lowRss = mkSystem {
    dev.johnrinehart.kitkat-rs.enable = true;
  };
  faster = mkSystem {
    dev.johnrinehart.kitkat-rs = {
      enable = true;
      variant = "faster";
    };
  };
  fastest = mkSystem {
    dev.johnrinehart.kitkat-rs = {
      enable = true;
      variant = "fastest";
    };
  };
  shellTools = mkSystem {
    dev.johnrinehart.packages.shell.enable = true;
  };

  lowRssPackage = lowRss.pkgs.dev.johnrinehart.kitkat-rs-low-rss;
  fasterPackage = faster.pkgs.dev.johnrinehart.kitkat-rs-faster;
  fastestPackage = fastest.pkgs.dev.johnrinehart.kitkat-rs-fastest;
in
assert !server.config.dev.johnrinehart.kitkat-rs.enable;
assert lowRss.config.dev.johnrinehart.kitkat-rs.package == lowRssPackage;
assert builtins.elem lowRssPackage lowRss.config.environment.systemPackages;
assert faster.config.dev.johnrinehart.kitkat-rs.package == fasterPackage;
assert builtins.elem fasterPackage faster.config.environment.systemPackages;
assert fastest.config.dev.johnrinehart.kitkat-rs.package == fastestPackage;
assert builtins.elem fastestPackage fastest.config.environment.systemPackages;
assert shellTools.config.dev.johnrinehart.kitkat-rs.enable;
assert builtins.elem shellTools.config.dev.johnrinehart.kitkat-rs.package
  shellTools.config.environment.systemPackages;
assert lib.getExe lowRssPackage == "${lowRssPackage}/bin/kitkat-rs";
pkgs.runCommand "kitkat-rs-module-evaluation" { } ''
  touch $out
''
