# ~/.config/secretspec/config.toml text: a `keepass` provider for a KeePassXC
# database, made the default, plus one alias per entry of `aliases` for a
# single item of the same database. Used by the NixOS module
# (nixos-modules/secretspec.nix) and the Mac host
# (darwin-configurations/mbp-host/secretspec.nix).
#
# The master password is read from the machine's own keyring (the macOS
# Keychain, gnome-keyring on Linux), stored once with
#
#   secretspec config provider login keepass --reason "store master password"
#
# run from ~. The credential is pinned to one keyring item, so every
# project's manifest opens the database with the same item, and on the Mac
# with the same keychain trust, instead of each wanting its own
# <project>/_provider/password.
{
  lib,
  # Absolute path of the .kdbx file.
  database,
  keyringItem,
  # name -> { item; description }: providers for one database item each.
  aliases,
}:
let
  credentials = ''credentials = { password = { provider = "keyring", ref = { item = "${keyringItem}" } } }'';
  comment = text: lib.concatMapStrings (line: "# ${line}\n") (lib.splitString "\n" text);
  alias =
    name: a:
    lib.optionalString (a.description != "") (comment a.description)
    + ''
      ${name} = { uri = "kdbx:${database}", ref = { item = "${a.item}" }, ${credentials} }
    '';
in
''
  [defaults]
  # New secrets (`secretspec set` without --provider) go to KeePassXC too.
  provider = "keepass"
  profile = "default"

  [defaults.providers]
  # KeePassXC database, read directly (KeePassXC need not be running); its
  # master password comes from this machine's keyring, one entry for every
  # project.
  keepass = { uri = "kdbx:${database}", ${credentials} }
''
+ lib.concatStrings (lib.mapAttrsToList alias aliases)
