{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.slack;
in
{
  options.dev.johnrinehart.slack = {
    enable = lib.mkEnableOption "slack desktop application";
  };

  config = lib.mkIf cfg.enable {
    dev.johnrinehart.nix.allowedUnfreePackages = [ "slack" ];
    environment.systemPackages = [ pkgs.slack ];
  };
}
