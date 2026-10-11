inputs:
let
  inherit (inputs.self) lib;
  johnosModules = inputs.self;
in
lib.mapAttrs (
  dir: _:
  lib.nixosSystem {
    modules = [
      {
        nixpkgs.overlays = [ johnosModules.overlays.default ];
      }
      ./${dir}
      johnosModules.nixosModules.default
    ];

    specialArgs = { inherit inputs; };
  }
) (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./.))
