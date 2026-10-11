{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.programs.git.meld;
in
{
  options.dev.johnrinehart.programs.git.meld = {
    enable = lib.mkEnableOption "git-meld autosquash metadata preservation tool";

    package = lib.mkPackageOption pkgs.dev.johnrinehart "git-meld" { };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
  };
}
