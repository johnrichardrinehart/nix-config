# PXE server for a NixOS configuration that imports nixosModules.netboot:
# proxy DHCP and TFTP from dnsmasq, the kernel and initrd over HTTP from
# darkhttpd. Runs on Linux and macOS; see netboot-server.sh.
#
# `tree` and `ipxeEfi` are x86_64-linux build outputs; this package only
# names them, so the server itself can run on any host that has them.
{
  lib,
  stdenv,
  writeShellApplication,
  coreutils,
  darkhttpd,
  dnsmasq,
  gawk,
  iproute2,

  name,
  # Directory with bzImage, initrd and netboot.ipxe.
  tree,
  # iPXE EFI binary whose embedded script chains tftp://<server>/boot.ipxe.
  ipxeEfi,
}:
writeShellApplication {
  inherit name;
  runtimeInputs = [
    coreutils
    darkhttpd
    dnsmasq
    gawk
  ]
  ++ lib.optional stdenv.hostPlatform.isLinux iproute2;
  text = lib.replaceStrings [ "@name@" "@tree@" "@ipxeEfi@" ] [ name "${tree}" "${ipxeEfi}" ] (
    builtins.readFile ./netboot-server.sh
  );
  meta.description = "Serve ${name} to UEFI PXE clients";
}
