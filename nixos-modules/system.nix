# Edit this configuration file to define what should be installed on

# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.dev.johnrinehart.system;
  primaryUser = config.dev.johnrinehart.users.primary;
in
{
  options.dev.johnrinehart.system = {
    enable = lib.mkEnableOption "John's system";
    ls.timeStyle = lib.mkOption {
      type = lib.types.str;
      default = "+%b %e %H:%M:%S";
      example = "full-iso";
      description = ''
        GNU ls timestamp format exported through TIME_STYLE. Downstream
        configurations may use a named style or a custom date format.
      '';
    };
    suspendVerb = lib.mkOption {
      type = lib.types.enum [
        "suspend-then-hibernate"
        "suspend"
      ];
      default = "suspend-then-hibernate";
      description = ''
        `systemctl` verb behind the desktop's suspend key, lid switch and
        long-idle suspend. Hosts that cannot hibernate (no swap) need
        `suspend`: systemd refuses suspend-then-hibernate there, and the
        machine would stay awake.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.sessionVariables.TIME_STYLE = cfg.ls.timeStyle;
    # Hosts enable DHCP explicitly, per interface or globally.
    networking.useDHCP = lib.mkDefault false;

    system.stateVersion = "24.05"; # Did you read the comment?

    programs.zsh.enable = true;
    dev.johnrinehart.repo-manager.enable = lib.mkDefault true;

    # Define a user account. Don't forget to set a password with ‘passwd’.
    ## consider using https://stackoverflow.com/a/54505212 for merging extraGroups
    users = {
      groups = {
        ${primaryUser} = { };
      };
      users = {
        ${primaryUser} = {
          isNormalUser = true;
          extraGroups = [
            "wheel"
            "vboxsf"
            "audio"
            "docker"
            "adbusers"
            "video"
          ]; # Enable ‘sudo’ for the user. And enable access to VBox shared folders
          shell = pkgs.zsh;
          group = primaryUser;
        };
      };
    };

    # Cf.
    # 1. https://github.com/systemd/systemd/issues/32420
    # 2. https://github.com/systemd/systemd/issues/27839
    systemd.sleep.settings.Sleep = {
      HibernateDelaySec = "5m";
    };

    # https://github.com/VTimofeenko/home-manager/blob/3d9ea6d74ee511cd8664f4a486ce65bd39e03ea8/experiments/homed.nix
    # systemd.package = pkgs.systemd.override (old: { withHomed = true; });

    # cidkid from #nixos
    # systemd.package = (pkgs.systemd.override { withHomed = true; });

    # overlay: NobbZ says don't do this because
    # https://zimbatm.com/notes/1000-instances-of-nixpkgs
    # nixpkgs.overlays = [
    #   (self: super: {
    #     systemd = (super.systemd.override {
    #       withHomed = true;
    #       withCryptsetup = true;
    #       cryptsetup = super.cryptsetup;
    #     });
    #   })
    # ];
  };
}
