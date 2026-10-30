# Options shared by the NixOS module (nixos-modules/secretspec.nix) and the
# Mac host (darwin-configurations/mbp-host/secretspec.nix) for secretspec
# backed by one KeePassXC database (lib/secretspec-keepass-config.nix).
{ lib }:
let
  inherit (lib) mkOption types;
in
{
  database = mkOption {
    type = types.nullOr types.str;
    default = null;
    example = "keepass/secrets.kdbx";
    description = ''
      KeePassXC database, relative to the home directory. When set,
      ~/.config/secretspec/config.toml makes it the default provider,
      `keepass`.
    '';
  };

  keyringItem = mkOption {
    type = types.str;
    default = "secretspec/john-home/_provider/password";
    description = "Keyring item that holds the database master password, for every project.";
  };

  aliases = mkOption {
    type = types.attrsOf (
      types.submodule {
        options = {
          item = mkOption {
            type = types.str;
            description = "Database entry the alias reads.";
          };
          description = mkOption {
            type = types.str;
            default = "";
            description = "Comment written above the alias.";
          };
        };
      }
    );
    default = { };
    description = "Providers that read one entry of the database each, for manifests that name them.";
  };

  manifest = mkOption {
    type = types.nullOr types.str;
    default = null;
    example = "keepass/secretspec.toml";
    description = ''
      Shared project manifest, relative to the home directory. ~/secretspec.toml
      links to it, so `secretspec` run from ~ reads it, and edits change it in
      place without a rebuild.
    '';
  };
}
