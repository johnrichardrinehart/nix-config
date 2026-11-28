# Cross-compiled rmux (without web/HTTP server feature) and rmux-deck (without
# systemd in its runtime PATH; src/accounting.rs falls back cleanly when
# systemd-run is absent).
{
  buildPackages,
  lib,
  makeBinaryWrapper,
  rmuxDeckSrc,
  rmuxSrc,
  rustPlatform,
  sqlite,
  stdenv,
}:
let
  rmuxManifest = builtins.fromTOML (builtins.readFile "${rmuxSrc}/Cargo.toml");
  rmuxDeckManifest = builtins.fromTOML (builtins.readFile "${rmuxDeckSrc}/Cargo.toml");

  rmux = rustPlatform.buildRustPackage {
    pname = rmuxManifest.package.name;
    inherit (rmuxManifest.workspace.package) version;
    src = rmuxSrc;

    cargoLock.lockFile = "${rmuxSrc}/Cargo.lock";
    # Disable the default "web" feature so no HTTP server is built or included.
    buildNoDefaultFeatures = true;
    doCheck = false;
  };

  # Strip git source lines for rmux workspace crates from Cargo.lock so
  # importCargoLock resolves them as local path dependencies from rmuxSrc
  # without reaching out over SSH during builds.
  rmuxLockUrl = "source = \"git+ssh://forgejo@office-desktop.tail5ca7.ts.net/jrestivo/rmux?rev=69497e361989ef4f7760978d94c99abad1aa2610#69497e361989ef4f7760978d94c99abad1aa2610\"";
  patchedCargoLock = builtins.replaceStrings [ "${rmuxLockUrl}\n" ] [ "" ] (
    builtins.readFile "${rmuxDeckSrc}/Cargo.lock"
  );

  patchedCargoLockFile = buildPackages.writeText "rmux-deck-Cargo.lock" patchedCargoLock;

  patchedSrc = buildPackages.runCommand "rmux-deck-src" { } ''
    mkdir -p $out
    cp -r ${rmuxDeckSrc}/Cargo.toml ${rmuxDeckSrc}/src $out/
    chmod -R u+w $out
    cp ${patchedCargoLockFile} $out/Cargo.lock
    substituteInPlace $out/Cargo.toml \
      --replace-fail 'rmux-client = { git = "ssh://forgejo@office-desktop.tail5ca7.ts.net/jrestivo/rmux", rev = "69497e361989ef4f7760978d94c99abad1aa2610" }' \
                     'rmux-client = { path = "${rmuxSrc}/crates/rmux-client" }' \
      --replace-fail 'rmux-os = { git = "ssh://forgejo@office-desktop.tail5ca7.ts.net/jrestivo/rmux", rev = "69497e361989ef4f7760978d94c99abad1aa2610" }' \
                     'rmux-os = { path = "${rmuxSrc}/crates/rmux-os" }' \
      --replace-fail 'rmux-proto = { git = "ssh://forgejo@office-desktop.tail5ca7.ts.net/jrestivo/rmux", rev = "69497e361989ef4f7760978d94c99abad1aa2610" }' \
                     'rmux-proto = { path = "${rmuxSrc}/crates/rmux-proto" }' \
      --replace-fail 'rmux-sdk = { git = "ssh://forgejo@office-desktop.tail5ca7.ts.net/jrestivo/rmux", rev = "69497e361989ef4f7760978d94c99abad1aa2610" }' \
                     'rmux-sdk = { path = "${rmuxSrc}/crates/rmux-sdk" }'
  '';
in
rustPlatform.buildRustPackage {
  pname = rmuxDeckManifest.package.name;
  inherit (rmuxDeckManifest.package) version;
  src = patchedSrc;

  cargoLock.lockFileContents = patchedCargoLock;
  nativeBuildInputs = [ makeBinaryWrapper ];
  buildInputs = [ sqlite ];
  doCheck = false;

  # Target C compiler for rusqlite's bundled SQLite build when cross-compiling.
  CC_aarch64_unknown_linux_gnu = lib.optionalString (
    stdenv.hostPlatform.system == "aarch64-linux"
  ) "${stdenv.cc.targetPrefix}cc";

  postInstall = ''
    wrapProgram $out/bin/rmux-deck \
      --prefix PATH : ${lib.makeBinPath [ rmux ]}
  '';

  passthru = { inherit rmux; };

  meta = {
    description = "Minimal rmux-backed session deck";
    license = with lib.licenses; [
      mit
      asl20
    ];
    mainProgram = "rmux-deck";
  };
}
