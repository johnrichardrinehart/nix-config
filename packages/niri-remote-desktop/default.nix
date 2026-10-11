{
  lib,
  stdenv,
  pkg-config,
  wayland,
  wayland-scanner,
  wlr-protocols,
  python3Packages,
  niri,
}:

let
  python = python3Packages.python.withPackages (ps: [ ps.dbus-next ]);
in
stdenv.mkDerivation {
  pname = "niri-remote-desktop";
  version = "0.1.0";
  src = ./.;

  nativeBuildInputs = [
    pkg-config
    wayland-scanner
  ];
  buildInputs = [ wayland ];

  buildPhase = ''
    runHook preBuild
    wayland-scanner client-header \
      ${wlr-protocols}/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml \
      virtual-pointer-client-protocol.h
    wayland-scanner private-code \
      ${wlr-protocols}/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml \
      virtual-pointer-protocol.c
    $CC $NIX_CFLAGS_COMPILE -Wall -Wextra -Werror \
      -o niri-remote-pointer pointer.c virtual-pointer-protocol.c \
      $(pkg-config --cflags --libs wayland-client)
    substitute service.py niri-remote-desktop \
      --replace-fail @python@ ${lib.getExe python} \
      --replace-fail @helper@ $out/libexec/niri-remote-pointer \
      --replace-fail @niri@ ${lib.getExe niri}
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ${lib.getExe python} -m unittest -v test_service.py
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 niri-remote-pointer $out/libexec/niri-remote-pointer
    install -Dm755 niri-remote-desktop $out/bin/niri-remote-desktop
    runHook postInstall
  '';

  meta = {
    description = "Mutter RemoteDesktop compatibility service for Niri";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "niri-remote-desktop";
  };
}
