{
  geoclue2-with-demo-agent,
  lib,
  python3,
  systemd,
  writeShellApplication,
}:
writeShellApplication {
  name = "daylight-display";
  runtimeInputs = [ python3 ];
  text = ''
    exec ${lib.getExe python3} ${./daylight_display.py} \
      --busctl ${lib.getExe' systemd "busctl"} \
      --geoclue ${geoclue2-with-demo-agent}/libexec/geoclue-2.0/demos/where-am-i \
      "$@"
  '';
  meta = {
    description = "Apply Wayland display brightness and color temperature at solar breakpoints";
    license = lib.licenses.mit;
    mainProgram = "daylight-display";
    platforms = lib.platforms.linux;
  };
}
