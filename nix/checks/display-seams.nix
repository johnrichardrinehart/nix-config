# The display-seams geometry (packages/display-seams/Seams.swift) holds no
# AppKit, so its tests run on every system the flake checks.
{ lib, pkgs }:
pkgs.runCommandCC "display-seams-tests" { nativeBuildInputs = [ pkgs.swift ]; } ''
  cp ${../../packages/display-seams/Seams.swift} Seams.swift
  cp ${../../packages/display-seams/tests/main.swift} main.swift
  swiftc Seams.swift main.swift -o tests
  ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux "LD_LIBRARY_PATH=${pkgs.swiftPackages.Dispatch}/lib"} ./tests
  touch $out
''
