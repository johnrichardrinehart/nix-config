{
  lib,
  ffmpeg-headless,
  linux-pam,
  python3,
  stdenv,
  symlinkJoin,
  writeShellApplication,
}:
let
  python = python3.withPackages (ps: [
    ps.face-recognition
    ps.numpy
  ]);

  # PAM and the lock screen start the client often. The bare interpreter
  # starts in a fraction of the time that the face_recognition environment
  # needs.
  client = writeShellApplication {
    name = "face-auth";
    text = ''
      exec ${lib.getExe python3} -I ${./face_auth.py} "$@"
    '';
  };

  daemon = writeShellApplication {
    name = "face-authd";
    runtimeInputs = [ ffmpeg-headless ];
    text = ''
      exec ${lib.getExe python} -I ${./face_auth.py} "$@"
    '';
  };

  pamModule = stdenv.mkDerivation {
    name = "pam-biometrics";
    src = ./pam_biometrics.c;
    dontUnpack = true;
    buildInputs = [ linux-pam ];
    buildPhase = ''
      runHook preBuild
      $CC -shared -fPIC -O2 -Wall -Wextra -Werror -o pam_biometrics.so $src -lpam
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm0644 pam_biometrics.so $out/lib/security/pam_biometrics.so
      runHook postInstall
    '';
  };
in
symlinkJoin {
  name = "face-auth";
  paths = [
    client
    daemon
    pamModule
  ];
  passthru = { inherit python; };
  meta = {
    description = "Webcam face check and a PAM module that accepts a fingerprint or a face";
    license = lib.licenses.mit;
    mainProgram = "face-auth";
    platforms = lib.platforms.linux;
  };
}
