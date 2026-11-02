# Built with nixpkgs' Swift toolchain rather than Xcode's, like display-mode.
{
  runCommandCC,
  swift,
}:
runCommandCC "glance-idle-trigger"
  {
    nativeBuildInputs = [ swift ];
    meta.mainProgram = "glance-idle-trigger";
  }
  ''
    mkdir -p "$out/bin"
    swiftc -O ${./glance-idle-trigger.swift} -o "$out/bin/glance-idle-trigger"
  ''
