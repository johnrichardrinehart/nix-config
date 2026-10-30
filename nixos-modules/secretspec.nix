# secretspec (0.21, packages/secretspec: the pinned nixpkgs ships 0.10, which
# has no `kdbx:` provider), optionally backed by one KeePassXC database
# (lib/secretspec-keepass-config.nix).
#
# The mbp-apple-silicon guest reads the Mac's database: the Mac shares the
# directory that holds it (darwin-configurations/mbp-host/secretspec.nix),
# and vm-host-shares.service mounts it at the same path. The master password
# comes from gnome-keyring over the Secret Service, which a desktop login
# unlocks.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.secretspec;
  user = config.dev.johnrinehart.users.primary;
  home = config.users.users.${user}.home;
  inherit (lib) mkOption types;

  # "../" for each component of `dir`, then the manifest.
  relativeManifest = dir: lib.concatStrings (map (_: "../") (lib.splitString "/" dir)) + cfg.manifest;
in
{
  options.dev.johnrinehart.secretspec =
    import ../lib/secretspec-keepass-options.nix { inherit lib; }
    // {
      enable = lib.mkEnableOption "secretspec, optionally backed by a KeePassXC database";

      manifestLinks = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "code" ];
        description = ''
          Directories, relative to the home directory, that get a relative
          secretspec.toml link to `manifest` when they exist: secretspec looks
          for a manifest from the current directory upwards, so these see it
          before ~/secretspec.toml. A file already there is kept as
          secretspec.toml.before-keepass.
        '';
      };
    };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.manifestLinks == [ ] || cfg.manifest != null;
        message = "dev.johnrinehart.secretspec.manifestLinks needs dev.johnrinehart.secretspec.manifest.";
      }
    ];

    environment.systemPackages = [ (pkgs.callPackage ../packages/secretspec/package.nix { }) ];

    home-manager.users.${user} =
      { config, lib, ... }:
      {
        xdg.configFile."secretspec/config.toml" = lib.mkIf (cfg.database != null) {
          # Replaces a hand-made config.
          force = true;
          text = import ../lib/secretspec-keepass-config.nix {
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

        home.activation.secretspecManifestLinks = lib.mkIf (cfg.manifestLinks != [ ]) (
          lib.hm.dag.entryAfter [ "linkGeneration" ] (
            lib.concatMapStrings (dir: ''
              if [[ -d $HOME/${dir} && ! -L $HOME/${dir}/secretspec.toml ]]; then
                if [[ -e $HOME/${dir}/secretspec.toml ]]; then
                  run mv $HOME/${dir}/secretspec.toml $HOME/${dir}/secretspec.toml.before-keepass
                fi
                run ln -s ${relativeManifest dir} $HOME/${dir}/secretspec.toml
              fi
            '') cfg.manifestLinks
          )
        );
      };
  };
}
