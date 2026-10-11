{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.xmonad;
  terminalEmulator = config.dev.johnrinehart.users.terminalEmulator;
in
{
  options.dev.johnrinehart.xmonad = {
    enable = lib.mkEnableOption "John's xmonad config";
  };

  config = lib.mkIf cfg.enable {
    services.xserver.windowManager.xmonad = {
      enable = true;
      enableContribAndExtras = true;

      extraPackages = hp: [
        hp.dbus
        hp.monad-logger
      ];

      config = pkgs.replaceVars ./config.hs {
        terminal_emulator = lib.getExe terminalEmulator.package;
        terminal_emulator_class = terminalEmulator.package.windowClass or terminalEmulator.package.pname;
      };
    };
  };
}
