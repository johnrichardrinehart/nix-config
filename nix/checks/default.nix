{
  inputs,
  pkgs,
}:
let
  inherit (inputs.nixpkgs) lib;
in
{
  agent-tools-module = import ./agent-tools-module.nix { inherit inputs lib pkgs; };
  auto-suspend-module = import ./auto-suspend-module.nix { inherit inputs lib pkgs; };
  brightness-sync = import ./brightness-sync.nix { inherit lib pkgs; };
  daylight-display-module = import ./daylight-display-module.nix { inherit inputs lib pkgs; };
  git-meld-module = import ./git-meld-module.nix { inherit inputs lib pkgs; };
  kitkat-rs-module = import ./kitkat-rs-module.nix { inherit inputs lib pkgs; };
  mycelium-module = import ./mycelium-module.nix { inherit inputs lib pkgs; };
  mycelium-tls = import ./mycelium-tls.nix { inherit pkgs; };
  nebula-registry = import ./nebula-registry.nix { inherit lib pkgs; };
  slicemk-update = pkgs.runCommand "slicemk-update-check" { } ''
    export PYTHONDONTWRITEBYTECODE=1
    export SLICEMK_FIRMWARE=${pkgs.dev.johnrinehart.slicemk-firmware}/zmk.uf2
    cd ${../../packages/slicemk-update}
    ${pkgs.python3}/bin/python3 -m unittest -v test_update
    touch "$out"
  '';
  ssh-session = import ./ssh-session.nix { inherit lib pkgs; };

}
// lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
  slicemk-host-bluetooth = import ../../packages/slicemk-update/host-bluetooth-check.nix {
    inherit pkgs;
    firmwareSource = pkgs.applyPatches {
      src = pkgs.dev.johnrinehart.slicemk-firmware.src;
      patches = pkgs.dev.johnrinehart.slicemk-firmware.patches;
    };
  };
}
