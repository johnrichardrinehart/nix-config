{ lib, pkgs }:
let
  package = pkgs.callPackage ../../packages/nebula-registry { };
  source = ../../packages/nebula-registry;
in
pkgs.runCommand "nebula-registry-tests"
  {
    nativeBuildInputs = [ pkgs.openssl ];
  }
  ''
    export PYTHONDONTWRITEBYTECODE=1
    export PYTHONPATH=${source}
    ${lib.getExe package.passthru.python} ${source}/test_nebula_registry.py
    touch $out
  ''
