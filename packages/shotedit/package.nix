# Built with nixpkgs' Swift toolchain rather than Xcode's, so the build stays
# pure and does not depend on the Xcode license having been accepted.
#
# The binary is named shotedit-<tag>, where the tag hashes what determines
# the compiled binary: the source and the compiler, so provision-mac's
# summary names the build. The Mac host runs a signed copy under the fixed
# name `shotedit` (darwin-configurations/mbp-host/signed-copies.nix), so its
# Accessibility grant survives rebuilds.
{
  runCommandCC,
  swift,
}:
let
  source = ./shotedit.swift;
  tag = builtins.substring 0 8 (
    builtins.hashString "sha256" (builtins.unsafeDiscardStringContext "${source} ${swift}")
  );
  name = "shotedit-${tag}";
in
runCommandCC name
  {
    nativeBuildInputs = [ swift ];
    passthru = { inherit tag; };
    meta.mainProgram = name;
  }
  ''
    mkdir -p "$out/bin"
    swiftc -O ${source} -o "$out/bin/${name}"
  ''
