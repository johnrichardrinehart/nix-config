{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.desktop.displayBrightness;
in
{
  options.dev.johnrinehart.desktop.displayBrightness.enable = lib.mkEnableOption ''
    external monitor DDC/CI brightness and software dimming that follow the
    brightness-notify level set by the laptop brightness keys
  '';

  config = lib.mkIf cfg.enable {
    # DDC/CI needs /dev/i2c-* (i2c-dev, with seat access for the logged-in user).
    hardware.i2c.enable = true;

    # Pushes DDC/CI brightness to external monitors on each brightness-notify
    # level change and hotplug, and reapplies software dimming at login (gamma
    # resets while the backlight level is restored) and hotplug.
    systemd.user.services.brightness-sync = {
      description = "Keep external monitor and software brightness in step with the backlight";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "wl-gammarelay.service" ];
      serviceConfig = {
        ExecStart = lib.getExe pkgs.dev.johnrinehart.brightness-sync;
        Restart = "on-failure";
        RestartSec = "2s";
      };
    };
  };
}
