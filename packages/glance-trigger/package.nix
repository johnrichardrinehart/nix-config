# Built with nixpkgs' Swift toolchain rather than Xcode's, like display-mode.
{
  runCommandCC,
  swift,
}:
runCommandCC "glance-trigger"
  {
    nativeBuildInputs = [ swift ];
    meta.mainProgram = "glance-trigger";
  }
  ''
    mkdir -p "$out/bin"
    swiftc -O ${./glance-trigger.swift} -o "$out/bin/glance-trigger"
  ''
