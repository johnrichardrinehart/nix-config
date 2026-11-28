{ lib, pkgs }:
let
  package = pkgs.callPackage ../../packages/nebula-registry { };
in
assert lib.assertMsg (
  package.meta.mainProgram == "nebula-registry"
) "nebula-registry mainProgram mismatch";
pkgs.runCommand "nebula-registry-tests" { } ''
  test -x ${lib.getExe package}
  touch "$out"
''
