{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.desktop.xorg-xmonad;
in
{
  options.dev.johnrinehart.desktop.xorg-xmonad = {
    enable = lib.mkEnableOption "the Xorg with Xmonad configuration.";
  };

  imports = [
    ./xorg.nix
  ];

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.kitty ];

    dev.johnrinehart = {
      xorg.enable = true;
      sound.enable = true;
      packages.shell.enable = true;
      packages.editors.enable = true;
      packages.gui.enable = true;
      packages.devops.enable = true;
      packages.media.enable = true;
      packages.system.enable = true;
      packages.archive.enable = true;
      xmonad.enable = true;
      bluetooth.enable = true;
    };
  };
}
