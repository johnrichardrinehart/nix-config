{
  writeShellApplication,
  bash,
  bolt,
  coreutils,
  ddcutil,
  edid-decode,
  shellcheck-minimal,
  findutils,
  gnugrep,
  gnused,
  pciutils,
  systemd,
  usbutils,
  util-linux,
}:

writeShellApplication {
  name = "display-link-debug";
  runtimeInputs = [
    bolt
    coreutils
    ddcutil
    edid-decode
    findutils
    gnugrep
    gnused
    pciutils
    systemd
    usbutils
    util-linux
  ];
  text = builtins.readFile ./display-link-debug.sh;
  checkPhase = ''
    runHook preCheck
    ${bash}/bin/bash -n "$target"
    ${shellcheck-minimal}/bin/shellcheck "$target" ${./display-link-debug-test.sh}
    DISPLAY_LINK_PROGRAM="$target" \
      ${bash}/bin/bash ${./display-link-debug-test.sh}
    runHook postCheck
  '';
}
