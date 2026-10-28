# The keyboard-remap rules (packages/keyboard-remap/Rules.swift) hold no
# IOKit, CoreGraphics or AppKit, so their tests run without a window server.
{ pkgs }:
pkgs.runCommandCC "keyboard-remap-tests" { nativeBuildInputs = [ pkgs.swift ]; } ''
  cp ${../../packages/keyboard-remap/Rules.swift} Rules.swift
  cp ${../../packages/keyboard-remap/tests/main.swift} main.swift
  swiftc Rules.swift main.swift -o tests
  ./tests
  touch $out
''
