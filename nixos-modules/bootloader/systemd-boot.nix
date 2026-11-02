{
  config,
  lib,
  ...
}:
let
  cfg = config.dev.johnrinehart.boot.loader.systemd-boot;
in
{
  options.dev.johnrinehart.boot.loader.systemd-boot = {
    enable = lib.mkEnableOption "John's system-boot config";
    configurationLimit = lib.mkOption {
      description = "Number of generations to preserve in the boot list";
      default = 20;
      type = lib.types.int;
    };
  };

  config = lib.mkIf cfg.enable {
    boot.loader.systemd-boot = {
      enable = true;
      inherit (cfg) configurationLimit;
    };

    # bootctl warns that world-accessible boot file systems are a security
    # hole (the random seed lives on the ESP), so the ESP and XBOOTLDR, if
    # any, are mounted 0077.
    fileSystems =
      lib.genAttrs
        (
          [ config.boot.loader.efi.efiSysMountPoint ]
          ++ lib.optional (
            config.boot.loader.systemd-boot.xbootldrMountPoint != null
          ) config.boot.loader.systemd-boot.xbootldrMountPoint
        )
        (_: {
          options = [
            "umask=0077"
            "defaults"
          ];
        });
  };
}
