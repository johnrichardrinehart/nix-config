# Per-keyboard key remaps and per-app swallowed keys for macOS, without a
# driver. Configure it with the nix-darwin module in
# darwin-modules/keyboard-remap (flake output darwinModules.keyboard-remap).
#
# Built with nixpkgs' Swift toolchain rather than Xcode's, like display-seams.
{
  lib,
  stdenv,
  swift,
}:
stdenv.mkDerivation {
  pname = "keyboard-remap";
  version = "1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.difference (lib.fileset.fileFilter (file: file.hasExt "swift") ./.) ./tests;
  };

  nativeBuildInputs = [ swift ];

  # With more than one source file, only main.swift may hold top-level code.
  buildPhase = ''
    runHook preBuild
    swiftc -O Rules.swift Devices.swift Apps.swift main.swift -o keyboard-remap
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 keyboard-remap "$out/bin/keyboard-remap"
    runHook postInstall
  '';

  meta = {
    description = "Per-keyboard key remaps and per-app swallowed keys for macOS, without a driver";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
    mainProgram = "keyboard-remap";
  };
}
