{
  lib,
  nix,
  writeShellApplication,
}:
writeShellApplication {
  name = "prime-agent";
  runtimeInputs = [ nix ];
  text = ''
    exec nix --tarball-ttl 0 run github:johnrichardrinehart/prime-agent-nix -- "$@"
  '';

  meta = with lib; {
    description = "Shell wrapper that runs Prime Agent through prime-agent-nix";
    license = licenses.mit;
    mainProgram = "prime-agent";
    maintainers = [ ];
    platforms = platforms.linux;
  };
}
