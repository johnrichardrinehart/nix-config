{ lib, pkgs }:
pkgs.runCommand "brightness-sync-tests" { } ''
  export PYTHONDONTWRITEBYTECODE=1
  export PYTHONPATH=${../../packages/brightness-sync}
  ${lib.getExe pkgs.python3} ${../../packages/brightness-sync/test_brightness_sync.py}
  touch $out
''
