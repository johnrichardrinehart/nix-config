{
  coreutils,
  git,
  magic-wormhole-rs,
  makeWrapper,
  symlinkJoin,
  unzip,
  writeScriptBin,
  zip,
}:
let
  name = "git-patch-wormhole";
  runtimeInputs = [
    coreutils
    git
    magic-wormhole-rs
    unzip
    zip
  ];
  script = (writeScriptBin name (builtins.readFile ./git-patch-wormhole.sh)).overrideAttrs (old: {
    buildCommand = "${old.buildCommand}\npatchShebangs $out";
  });
in
symlinkJoin {
  inherit name;
  paths = [ script ] ++ runtimeInputs;
  buildInputs = [ makeWrapper ];
  postBuild = "wrapProgram $out/bin/${name} --prefix PATH : $out/bin";
}
