{
  lib,
  fetchFromGitHub,
  installShellFiles,
  kdlfmt,
  rustPlatform,
  stdenv,
  versionCheckHook,
  writeText,
}:

let
  kdl-rs = fetchFromGitHub {
    owner = "johnrichardrinehart";
    repo = "kdl-rs";
    rev = "15cbbcf8d20998ef70c79087eafbd7c9cc245571";
    hash = "sha256-tY50svSdptC3fb4TbULaL8FjxJnGTfZIaVypBy/iM88=";
  };
  kdl-rs-cargo-patch = writeText "kdlfmt-kdl-rs.patch" ''
    diff --git a/Cargo.lock b/Cargo.lock
    index eb14ff0..2274fd7 100644
    --- a/Cargo.lock
    +++ b/Cargo.lock
    @@ -414,13 +414,12 @@ dependencies = [

     [[package]]
     name = "kdl"
    -version = "6.5.0"
    -source = "registry+https://github.com/rust-lang/crates.io-index"
    -checksum = "81a29e7b50079ff44549f68c0becb1c73d7f6de2a4ea952da77966daf3d4761e"
    +version = "6.7.1"
     dependencies = [
      "kdl 4.7.1",
      "miette 7.6.0",
    - "num",
    + "num-traits",
    + "serde",
      "winnow",
     ]

    @@ -436,7 +435,7 @@ dependencies = [
      "ec4rs",
      "env_logger",
      "ignore",
    - "kdl 6.5.0",
    + "kdl 6.7.1",
      "log",
      "miette 7.6.0",
      "predicates",
    @@ -551,70 +550,6 @@ version = "0.3.0"
     source = "registry+https://github.com/rust-lang/crates.io-index"
     checksum = "61807f77802ff30975e01f4f071c8ba10c022052f98b3294119f3e615d13e5be"

    -[[package]]
    -name = "num"
    -version = "0.4.3"
    -source = "registry+https://github.com/rust-lang/crates.io-index"
    -checksum = "35bd024e8b2ff75562e5f34e7f4905839deb4b22955ef5e73d2fea1b9813cb23"
    -dependencies = [
    - "num-bigint",
    - "num-complex",
    - "num-integer",
    - "num-iter",
    - "num-rational",
    - "num-traits",
    -]
    -
    -[[package]]
    -name = "num-bigint"
    -version = "0.4.6"
    -source = "registry+https://github.com/rust-lang/crates.io-index"
    -checksum = "a5e44f723f1133c9deac646763579fdb3ac745e418f2a7af9cd0c431da1f20b9"
    -dependencies = [
    - "num-integer",
    - "num-traits",
    -]
    -
    -[[package]]
    -name = "num-complex"
    -version = "0.4.6"
    -source = "registry+https://github.com/rust-lang/crates.io-index"
    -checksum = "73f88a1307638156682bada9d7604135552957b7818057dcef22705b4d509495"
    -dependencies = [
    - "num-traits",
    -]
    -
    -[[package]]
    -name = "num-integer"
    -version = "0.1.46"
    -source = "registry+https://github.com/rust-lang/crates.io-index"
    -checksum = "7969661fd2958a5cb096e56c8e1ad0444ac2bbcd0061bd28660485a44879858f"
    -dependencies = [
    - "num-traits",
    -]
    -
    -[[package]]
    -name = "num-iter"
    -version = "0.1.45"
    -source = "registry+https://github.com/rust-lang/crates.io-index"
    -checksum = "1429034a0490724d0075ebb2bc9e875d6503c3cf69e235a8941aa757d83ef5bf"
    -dependencies = [
    - "autocfg",
    - "num-integer",
    - "num-traits",
    -]
    -
    -[[package]]
    -name = "num-rational"
    -version = "0.4.2"
    -source = "registry+https://github.com/rust-lang/crates.io-index"
    -checksum = "f83d14da390562dca69fc84082e73e548e1ad308d24accdedd2720017cb37824"
    -dependencies = [
    - "num-bigint",
    - "num-integer",
    - "num-traits",
    -]
    -
     [[package]]
     name = "num-traits"
     version = "0.2.19"
    @@ -1054,9 +989,9 @@ checksum = "589f6da84c646204747d1270a2a5661ea66ed1cced2631d546fdfb155959f9ec"

     [[package]]
     name = "winnow"
    -version = "0.6.24"
    +version = "1.0.4"
     source = "registry+https://github.com/rust-lang/crates.io-index"
    -checksum = "c8d71a593cc5c42ad7876e2c1fda56f314f3754c084128833e64f1345ff8a03a"
    +checksum = "23b97319f7b8343df12cc98938e5c3eb436064524c8d2b4e30a1d3a36eecdf81"
     dependencies = [
      "memchr",
     ]
    diff --git a/Cargo.toml b/Cargo.toml
    index 75fb78e..16cf34e 100644
    --- a/Cargo.toml
    +++ b/Cargo.toml
    @@ -31,6 +31,9 @@ miette = { version = "7.6.0", features = ["fancy"] }
     predicates = "3.1.4"
     tempfile = "3.27.0"

    +[patch.crates-io]
    +kdl = { path = "${kdl-rs}" }
    +
     # The profile that 'dist' will build with
     [profile.dist]
     inherits = "release"
  '';
in
rustPlatform.buildRustPackage {
  pname = "kdlfmt";
  inherit (kdlfmt) version src;

  cargoPatches = [ kdl-rs-cargo-patch ];
  cargoHash = "sha256-nMi61UNlZDVGH6YBTnsXdkfuI7KMIr/54SeRuLImUTs=";

  nativeBuildInputs = [ installShellFiles ];

  postInstall = lib.optionalString (stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
    installShellCompletion --cmd kdlfmt \
      --bash <($out/bin/kdlfmt completions bash) \
      --fish <($out/bin/kdlfmt completions fish) \
      --zsh <($out/bin/kdlfmt completions zsh)
  '';

  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "--version";
  doInstallCheck = true;

  passthru = (kdlfmt.passthru or { }) // {
    inherit kdl-rs;
  };

  meta = kdlfmt.meta // {
    description = "${kdlfmt.meta.description} (patched with John Rinehart's kdl-rs branch)";
  };
}
