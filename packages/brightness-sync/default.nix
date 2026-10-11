{
  brightness-notify,
  brightnessctl,
  ddcutil,
  lib,
  python3,
  systemd,
  writeShellApplication,
}:
writeShellApplication {
  name = "brightness-sync";
  text = ''
    exec ${lib.getExe python3} ${./brightness_sync.py} \
      --ddcutil ${lib.getExe ddcutil} \
      --brightnessctl ${lib.getExe brightnessctl} \
      --brightness-notify ${lib.getExe brightness-notify} \
      --udevadm ${lib.getExe' systemd "udevadm"} \
      "$@"
  '';
  meta = {
    description = "Keep external monitor DDC/CI brightness and software dimming in step with brightness-notify";
    license = lib.licenses.mit;
    mainProgram = "brightness-sync";
    platforms = lib.platforms.linux;
  };
}
