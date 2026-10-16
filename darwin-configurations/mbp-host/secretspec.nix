# secretspec on PATH, as a signed copy (signed-copies.nix).
#
# Its KeePassXC master password lives in the login keychain, whose items admit
# programs by code signature twice over: the access list ("wants to use your
# confidential information") and the partition list ("wants to access key").
# An ad hoc signed build asks both; a new build signed with the same
# certificate matches the access-list entry "Always Allow" recorded and asks
# once, for the partition list, which records each build's cdhash.
{ config, pkgs, ... }:
let
  copy = config.dev.johnrinehart.mbp-host.signedCopies.secretspec;
in
{
  dev.johnrinehart.mbp-host.signedCopies.secretspec.package =
    pkgs.callPackage ../../packages/secretspec/package.nix
      { };

  home-manager.users.${config.system.primaryUser}.home.packages = [ copy.link ];
}
