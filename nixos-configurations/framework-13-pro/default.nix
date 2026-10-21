# The Framework 13 Pro installed on its NVMe drive, as `install-to-disk`
# (framework-13-pro-netboot) lays it out: disko.nix.
{ inputs, ... }:
{
  imports = [
    inputs.disko.nixosModules.disko
    ./common.nix
    ./disko.nix
  ];

  dev.johnrinehart.boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Stage 1 unlocks the LUKS root on the NVMe drive, with a USB keyboard
  # or through a dock if need be.
  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "thunderbolt"
    "usbhid"
    "usb_storage"
    "uas"
    "sd_mod"
  ];
}
