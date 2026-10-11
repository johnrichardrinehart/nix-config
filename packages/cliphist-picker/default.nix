{
  cliphist,
  file,
  gobject-introspection,
  gtk4,
  gtk4-layer-shell,
  lib,
  niri,
  python3,
  stdenvNoCC,
  wl-clipboard,
  wrapGAppsHook4,
}:
let
  python = python3.withPackages (packages: [ packages.pygobject3 ]);
in
stdenvNoCC.mkDerivation {
  pname = "cliphist-picker";
  version = "0.2.0";

  src = ./.;

  nativeBuildInputs = [
    gobject-introspection
    wrapGAppsHook4
  ];

  buildInputs = [
    gtk4
    gtk4-layer-shell
    python
  ];

  postPatch = ''
    substituteInPlace cliphist_picker.py \
      --replace-fail '#!/usr/bin/env python3' '#!${lib.getExe python}' \
      --replace-fail '@cliphist@' '${lib.getExe cliphist}' \
      --replace-fail '@file@' '${lib.getExe file}' \
      --replace-fail '@niri@' '${lib.getExe niri}' \
      --replace-fail '@wl_copy@' '${lib.getExe' wl-clipboard "wl-copy"}'
  '';

  preFixup = ''
    gappsWrapperArgs+=(
      --prefix LD_PRELOAD : "${gtk4-layer-shell}/lib/libgtk4-layer-shell.so"
    )
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ${lib.getExe python} -m unittest -v test_cliphist_picker.py
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 cliphist_picker.py "$out/bin/cliphist-picker"
    runHook postInstall
  '';

  meta = with lib; {
    description = "Layer-shell clipboard history picker with automatic image previews";
    license = licenses.mit;
    mainProgram = "cliphist-picker";
    platforms = platforms.linux;
  };
}
