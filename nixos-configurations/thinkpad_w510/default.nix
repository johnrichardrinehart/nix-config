{
  lib,
  pkgs,
  config,
  ...
}:
{
  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "24.05";

  # Boot configuration
  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";
  };

  # Root filesystem already defined below, removing duplicate

  dev.johnrinehart = {
    # Temporarily disable complex s3/gocryptfs setup for building
    # s3_mount.enable = false;
    # gocryptfs.enable = false;
    profiles.laptop.enable = true;
    network = {
      enable = true;
      manager = "iwd";
    };
    nix.enable = true;
  };

  # The Intel Centrino Wi-Fi card (iwlwifi) needs its firmware files.
  hardware.enableRedistributableFirmware = true;

  networking.hostName = "thinkie";
  # iwd handles Wi-Fi. dhcpcd handles the wired port.
  networking.interfaces.enp0s25.useDHCP = true;

  # really noisy webcam
  programs.noisetorch.enable = true;

  fileSystems = {
    "/" = lib.mkForce {
      device = "UUID=4f338d98-cf03-4853-a2b8-2452e5494bb3";
      fsType = "bcachefs";
      # A new bcachefs version upgrades the on-disk format on the first mount
      # and checks the whole file system. That takes longer than the default
      # 90 s mount timeout, which kills the mount and fails the boot.
      options = [ "x-systemd.mount-timeout=infinity" ];
    };

    "/boot" = lib.mkForce {
      device = "/dev/disk/by-uuid/84EE-E35C";
      fsType = "vfat";
      options = [
        "fmask=0022"
        "dmask=0022"
      ];
    };
  };

  boot.initrd.luks.devices."dm-0".device =
    lib.mkForce "/dev/disk/by-uuid/002adea0-5c10-45a8-bc8a-701a0d71577b";

  services.upower.enable = true;

  environment.systemPackages = [
    pkgs.opensc
    pkgs.pcsc-tools
    pkgs.global-platform-pro
    config.boot.kernelPackages.v4l2loopback.bin
  ]
  ++ [ pkgs.nload ];

  services.pcscd.enable = true;

  boot.extraModulePackages = [ config.boot.kernelPackages.v4l2loopback.out ];
  boot.kernelModules = [ "v4l2loopback" ];
  boot.extraModprobeConfig = "options usb-storage quirks=152d:0562:u";

}
