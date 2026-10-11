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
  ssh-session = import ./ssh-session.nix { inherit lib pkgs; };

  slicemk-update = pkgs.runCommand "slicemk-update-check" { } ''
    export PYTHONDONTWRITEBYTECODE=1
    cd ${../../packages/slicemk-update}
    ${pkgs.python3}/bin/python3 -m unittest -v test_update
    touch "$out"
  '';
}
