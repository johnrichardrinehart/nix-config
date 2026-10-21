# `nix run .#netboot -- NAME`: builds nixosConfigurations.NAME's netboot
# tree (nixosModules.netboot) and serves it to UEFI PXE clients with
# dnsmasq (proxy DHCP or DHCP, and TFTP) and darkhttpd. Runs on Linux and
# macOS; see netboot.sh.
{
  lib,
  stdenv,
  writeShellApplication,
  coreutils,
  darkhttpd,
  dnsmasq,
  gawk,
  gnugrep,
  iproute2,

  # The flake whose nixosConfigurations NAME refers to by default.
  flake,
}:
writeShellApplication {
  name = "netboot";
  runtimeInputs = [
    coreutils
    darkhttpd
    dnsmasq
    gawk
    gnugrep
  ]
  ++ lib.optional stdenv.hostPlatform.isLinux iproute2;
  text = lib.replaceStrings [ "@flake@" ] [ (lib.escapeShellArg "path:${flake}") ] (
    builtins.readFile ./netboot.sh
  );
  meta.description = "Serve a netboot NixOS configuration to UEFI PXE clients";
}
