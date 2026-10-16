# Built with nixpkgs' Swift toolchain rather than Xcode's, like shotedit.
#
# The binary is named display-seams-<tag>, where the tag hashes what
# determines the compiled binary: the sources and the compiler, so
# provision-mac's summary names the build. It moves the pointer by posting
# events, which needs Accessibility; the Mac host runs a signed copy under the
# fixed name `display-seams` (darwin-configurations/mbp-host/signed-copies.nix),
# so the grant survives rebuilds.
{
  runCommandCC,
  swift,
}:
let
  seams = ./Seams.swift;
  main = ./main.swift;
  tag = builtins.substring 0 8 (
    builtins.hashString "sha256" (builtins.unsafeDiscardStringContext "${seams} ${main} ${swift}")
  );
  name = "display-seams-${tag}";
in
runCommandCC name
  {
    nativeBuildInputs = [ swift ];
    passthru = { inherit tag; };
    meta.mainProgram = name;
  }
  ''
    # With more than one source file, only one named main.swift may hold
    # top-level code.
    cp ${seams} Seams.swift
    cp ${main} main.swift
    mkdir -p "$out/bin"
    swiftc -O Seams.swift main.swift -o "$out/bin/${name}"
  ''
