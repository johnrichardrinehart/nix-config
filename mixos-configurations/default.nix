inputs:
let
  inherit (inputs.nixpkgs) lib;
  inherit (inputs.self) mixosModules;
in
lib.mapAttrs (
  dir: _:
  inputs.nixos-uz801.lib.uz801System {
    buildSystem = "x86_64-linux";
    modules = [
      { _module.args = { inherit inputs; }; }
      mixosModules.sops
      mixosModules.cloudflare-ddns
      mixosModules.mycelium
      ./${dir}
    ];
  }
) (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./.))
