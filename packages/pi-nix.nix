{
  lib,
  nix,
  writeShellApplication,
}:
writeShellApplication {
  name = "pi";
  runtimeInputs = [ nix ];
  text = ''
    exec nix run github:lukasl-dev/pi.nix -- "$@"
  '';

  meta = with lib; {
    description = "Shell wrapper that runs Pi via lukasl-dev/pi.nix";
    license = licenses.mit;
    mainProgram = "pi";
    maintainers = [ ];
    platforms = platforms.linux ++ platforms.darwin;
  };
}
