# secretspec on PATH, as a signed copy (signed-copies.nix), optionally backed
# by one KeePassXC database (lib/secretspec-keepass-config.nix).
#
# Its KeePassXC master password lives in the login keychain, whose items admit
# programs by code signature twice over: the access list ("wants to use your
# confidential information") and the partition list ("wants to access key").
# An ad hoc signed build asks both; a new build signed with the same
# certificate matches the access-list entry "Always Allow" recorded and asks
# once, for the partition list, which records each build's cdhash.
#
# The database lives on this Mac, so it stays reachable while the VM is down.
# Its directory is shared with the guest at the same path (vm-shares.nix),
# so the guest's secretspec (nixos-modules/secretspec.nix) reads the same
# database and manifest.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.mbp-host.secretspec;
  copy = config.dev.johnrinehart.mbp-host.signedCopies.secretspec;
  user = config.system.primaryUser;
  home = config.users.users.${user}.home;
in
{
  options.dev.johnrinehart.mbp-host.secretspec = import ../../lib/secretspec-keepass-options.nix {
    inherit lib;
  };

  config = {
    dev.johnrinehart.mbp-host.signedCopies.secretspec = {
      package = pkgs.callPackage ../../packages/secretspec/package.nix { };
      # A command, not a launchd program. ~/.local/bin is not on PATH here, so
      # PATH reaches it through the link below.
      path = "${home}/.local/bin/secretspec";
    };

    dev.johnrinehart.mbp-host.vmShares = lib.mkIf (cfg.database != null) [
      {
        host = "${home}/${dirOf cfg.database}";
        guest = "/home/${user}/${dirOf cfg.database}";
        source = "host";
      }
    ];

    home-manager.users.${user} =
      { config, ... }:
      {
        home.packages = [ copy.link ];

        xdg.configFile."secretspec/config.toml" = lib.mkIf (cfg.database != null) {
          # Replaces a hand-made config.
          force = true;
          text = import ../../lib/secretspec-keepass-config.nix {
            inherit lib;
            inherit (cfg) keyringItem aliases;
            database = "${home}/${cfg.database}";
          };
        };

        home.file."secretspec.toml" = lib.mkIf (cfg.manifest != null) {
          source = config.lib.file.mkOutOfStoreSymlink "${home}/${cfg.manifest}";
          # Replaces a per-machine copy.
          force = true;
        };
      };
  };
}
