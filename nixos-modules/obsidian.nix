{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.desktop.obsidian;
in
{
  options.dev.johnrinehart.desktop.obsidian.enable =
    lib.mkEnableOption "the Obsidian desktop application";

  config = lib.mkIf cfg.enable {
    dev.johnrinehart.nix.allowedUnfreePackages = [ "obsidian" ];
    environment.systemPackages = [ pkgs.obsidian ];
  };
}
