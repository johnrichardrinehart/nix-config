# ~/shared kept in step with an encrypted Proton Drive directory by a
# systemd user unit (packages/shared-sync). The Mac runs the same daemon as a
# launchd agent (darwin-configurations/mbp-host/shared-sync.nix).
#
# The unit starts with the desktop session: secretspec needs gnome-keyring,
# which a desktop login unlocks, and its KeePassXC database, which on the
# mbp-apple-silicon guest vm-host-shares.service mounts. Until both are there
# it fails and tries again.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.sharedSync;
  user = config.dev.johnrinehart.users.primary;
  shared-sync = pkgs.callPackage ../packages/shared-sync/package.nix {
    secretspec = lib.getExe (pkgs.callPackage ../packages/secretspec/package.nix { });
  };
in
{
  options.dev.johnrinehart.sharedSync = {
    enable = lib.mkEnableOption "syncing ~/shared with a Proton Drive (shared-sync)";

    links = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "AGENTS.md" ];
      description = ''
        Files in the home directory that link to the same name in ~/shared,
        so edits there reach every machine without a rebuild. Linked whether
        or not this machine runs the sync.
      '';
    };
  };

  config.home-manager.users.${user} = lib.mkIf (cfg.enable || cfg.links != [ ]) (
    { config, ... }:
    {
      home.file = lib.genAttrs cfg.links (name: {
        source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/shared/${name}";
      });

      home.packages = lib.mkIf cfg.enable [ shared-sync ];

      systemd.user.services.shared-sync = lib.mkIf cfg.enable {
        Unit = {
          Description = "Sync ~/shared with the Proton Drive";
          After = [ "graphical-session.target" ];
          PartOf = [ "graphical-session.target" ];
          StartLimitIntervalSec = 0;
        };
        Service = {
          ExecStart = lib.getExe shared-sync;
          Restart = "always";
          RestartSec = 30;
        };
        Install.WantedBy = [ "graphical-session.target" ];
      };
    }
  );
}
