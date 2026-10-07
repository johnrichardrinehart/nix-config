# Uploads files as GitHub user-attachments (the github.com/user-attachments/assets/...
# URLs that issue and PR text embeds) with curl, by logging in to the web UI. The caller
# passes the account in GH_UPLOAD_LOGIN, GH_UPLOAD_PASSWORD and GH_UPLOAD_TOTP_SECRET;
# see the header of gh-upload-script.sh.
{
  coreutils,
  curl,
  file,
  gawk,
  git,
  gnugrep,
  gnused,
  jq,
  lib,
  makeWrapper,
  python3,
  symlinkJoin,
  writeScriptBin,
}:
let
  name = "gh-upload-script";
  runtimeInputs = [
    coreutils
    curl
    file
    gawk
    git
    gnugrep
    gnused
    jq
    python3
  ];
  script = (writeScriptBin name (builtins.readFile ./gh-upload-script.sh)).overrideAttrs (old: {
    buildCommand = "${old.buildCommand}\npatchShebangs $out";
  });
in
symlinkJoin {
  inherit name;
  paths = [ script ];
  nativeBuildInputs = [ makeWrapper ];
  postBuild = "wrapProgram $out/bin/${name} --prefix PATH : ${lib.makeBinPath runtimeInputs}";
  meta = {
    description = "Upload files as GitHub user-attachments through the web UI";
    mainProgram = name;
    platforms = lib.platforms.unix;
  };
}
