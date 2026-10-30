# ~/shared kept in step with an encrypted Proton Drive directory by a launchd
# agent (packages/shared-sync). Linux machines run the same daemon as a
# systemd user unit (nixos-modules/shared-sync.nix).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.mbp-host.sharedSync;
  user = config.system.primaryUser;
  shared-sync = pkgs.callPackage ../../packages/shared-sync/package.nix {
    # The signed copy, whose signature the keychain item for the KeePassXC
    # master password trusts.
    secretspec = config.dev.johnrinehart.mbp-host.signedCopies.secretspec.path;
  };
in
{
  options.dev.johnrinehart.mbp-host.sharedSync = {
    enable = lib.mkEnableOption "syncing ~/shared with a Proton Drive (shared-sync)";

    links = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "AGENTS.md" ];
      description = ''
        Files in the home directory that link to the same name in ~/shared,
        so edits there reach every machine without a rebuild.
      '';
    };
  };

  config = lib.mkMerge [
    {
      home-manager.users.${user} =
        { config, ... }:
        {
          home.file = lib.genAttrs cfg.links (name: {
            source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/shared/${name}";
          });
        };
    }
    (lib.mkIf cfg.enable {
      dev.johnrinehart.provisionMac.manualSteps."Shared directory: sync with the Proton Drive" = {
        check = ''
          find "$HOME/.local/state/shared-sync/last-sync" -mmin -10 2>/dev/null | grep -q .
        '';
        instructions = ''
          The shared-sync launchd agent syncs ~/shared, and it has not completed a
          sync in the last 10 minutes. It needs PROTON_USERNAME, PROTON_PASSWORD,
          PROTON_TOTP_SECRET and DIR_SHARED_RCLONE_PASSWORD in the `shared-sync`
          scope of ~/secretspec.toml (run `secretspec set <KEY> --reason "..."`
          from ~). Its log is /tmp/shared-sync.log; it tries again after 30 s.
        '';
      };

      home-manager.users.${user} = {
        home.packages = [ shared-sync ];

        launchd.agents.shared-sync = {
          enable = true;
          config = {
            ProgramArguments = [ (lib.getExe shared-sync) ];
            RunAtLoad = true;
            # Again after any exit (secretspec locked out, the watcher gone).
            KeepAlive = true;
            ThrottleInterval = 30;
            StandardOutPath = "/tmp/shared-sync.log";
            StandardErrorPath = "/tmp/shared-sync.log";
          };
        };
      };
    })
  ];
}
