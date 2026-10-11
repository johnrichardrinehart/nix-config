{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.i3;
  terminalEmulator = config.dev.johnrinehart.users.terminalEmulator.package;
in
{
  options.dev.johnrinehart.i3 = {
    enable = lib.mkEnableOption "John's i3 config";
  };

  config = lib.mkIf cfg.enable {
    dev.johnrinehart.xorg.enable = true;

    services.xserver.windowManager.i3 = {
      configFile = pkgs.replaceVars ./i3.conf {
        terminal_emulator = lib.getExe terminalEmulator;
      };
      enable = true;
    };
  };
}
