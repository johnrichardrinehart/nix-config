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
    rev = "d4ad4e8d22886a47a79d1cb99d5cdaa6b927bef1";
    hash = "sha256-HBAq3aSQ53EnBDV+1yMh89K5catwCQcy0qMdoFuLsIs=";
  };
  kdl-rs-cargo-patch = writeText "kdlfmt-kdl-rs.patch" ''
    diff --git a/Cargo.lock b/Cargo.lock
    index 59fdedb..5a094ea 100644
    --- a/Cargo.lock
    +++ b/Cargo.lock
    @@ -416,8 +416,6 @@ dependencies = [
     [[package]]
     name = "kdl"
     version = "6.5.0"
    -source = "registry+https://github.com/rust-lang/crates.io-index"
    -checksum = "81a29e7b50079ff44549f68c0becb1c73d7f6de2a4ea952da77966daf3d4761e"
     dependencies = [
      "kdl 4.7.1",
      "miette 7.6.0",
    @@ -1046,9 +1044,9 @@ checksum = "45e46c0661abb7180e7b9c281db115305d49ca1709ab8242adf09666d2173c65"

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
    index 9b3b2df..516e7e5 100644
    --- a/Cargo.toml
    +++ b/Cargo.toml
    @@ -31,6 +31,9 @@ miette = { version = "7.6.0", features = ["fancy"] }
     predicates = "3.1.4"
     tempfile = "3.26.0"

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
  cargoHash = "sha256-+F/XG2mmamqcoPJsOuInU7USmeQyNT3mFIpgAdRaTzs=";

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
