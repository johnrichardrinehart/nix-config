{
  lib,
  coreutils,
  fuzzel,
  gawk,
  jq,
  niri,
  writeShellApplication,
}:
writeShellApplication {
  name = "focus-or-spawn";

  runtimeInputs = [
    coreutils
    fuzzel
    gawk
    jq
    niri
  ];

  text = builtins.readFile ./focus-or-spawn.sh;

  meta = {
    description = "Application launcher that focuses the window of single-window apps";
    license = lib.licenses.mit;
    mainProgram = "focus-or-spawn";
    platforms = lib.platforms.linux;
  };
}
