{
  lib,
  pkgs,
  config,
  ...
}:
{
  imports = [ ./nebula.nix ];

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = "24.05";

  # Boot configuration
  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";
  };
  # /boot is a 2 GiB ext4 partition; GRUB (BIOS, core in sda1) reads it
  # directly. nixpkgs installs the bcachefs module with its debug info:
  # 13.6 MiB compressed in each initrd, 1.2 MiB when stripped.
  boot.bcachefs.modulePackage =
    (config.boot.kernelPackages.callPackage config.boot.bcachefs.package.kernelModule { }).overrideAttrs
      (old: {
        makeFlags = old.makeFlags ++ [ "INSTALL_MOD_STRIP=1" ];
      });
  # The W510 has a TPM 1.2, which systemd cannot unlock with.
  boot.initrd.systemd.tpm2.enable = false;

  # Root filesystem already defined below, removing duplicate

  dev.johnrinehart = {
    # Temporarily disable complex s3/gocryptfs setup for building
    # s3_mount.enable = false;
    # gocryptfs.enable = false;
    profiles.laptop.enable = true;
    initrdPkcs11.enable = true;
    network = {
      enable = true;
      manager = "iwd";
    };
    nix.enable = true;

    # `root-shell` opens a root shell without a password for root and wheel
    # members (nixos-modules/tmux-root-shell.nix).
    tmux.rootShell.enable = true;

    # pam-biometrics: a swipe on the UPEK TouchStrip (147e:2016) or a face
    # satisfies the biometric step after the password. The webcam has no
    # infrared sensor, so a photo can pass for a face; the check can only
    # reject an attempt. The password is always required.
    desktop.greetd_niri = {
      fingerprint.enable = true;
      face = {
        enable = true;
        device = "/dev/v4l/by-id/usb-Chicony_Electronics_Co.__Ltd._Integrated_Camera-video-index0";
        inputFormat = "mjpeg";
      };
      # The 1600x900 panel is the hardware ceiling; scale 0.8 gives a
      # 2000x1125 logical desktop. Tighter gaps reclaim space; the ring is
      # thinned from the shared 10. niri rejects a second `layout` node in
      # one file but merges included files, so only these keys override
      # the shared niri.kdl.
      niri.extraConfig = ''
        include "${pkgs.writeText "thinkie-niri.kdl" ''
          output "LVDS-1" {
              scale 0.8
          }
          layout {
              gaps 6
              focus-ring {
                  width 7
              }
          }
        ''}"
      '';
    };
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
      device = "/dev/disk/by-uuid/6aa0a06c-5ef2-4111-a30c-162ae10ee1a9";
      fsType = "ext4";
    };
  };

  boot.initrd.luks.devices."dm-0" = {
    device = lib.mkForce "/dev/disk/by-uuid/002adea0-5c10-45a8-bc8a-701a0d71577b";
    # Unlock with the PIVKey or the passphrase. Keyslot 1 holds the card's
    # systemd-pkcs11 token, and keyslot 0 holds the passphrase. With the card
    # in the reader, stage 1 asks for its PIN. Without the card, stage 1 waits
    # 15 s (token-timeout) and then asks for the passphrase.
    #
    # "auto" reads the card's URI from the token in the LUKS header. If that
    # token is gone, the patched stage-1 systemd-cryptsetup
    # (nixos-modules/initrd-pkcs11.nix) asks for the passphrase at once.
    crypttabExtraOpts = [
      "pkcs11-uri=auto"
      "token-timeout=15s"
    ];
  };

  services.upower.enable = true;

  environment.systemPackages = [
    pkgs.pcsc-tools
    pkgs.global-platform-pro
    config.boot.kernelPackages.v4l2loopback.bin
  ]
  ++ [ pkgs.nload ];

  boot.extraModulePackages = [ config.boot.kernelPackages.v4l2loopback.out ];
  boot.kernelModules = [ "v4l2loopback" ];
  boot.extraModprobeConfig = "options usb-storage quirks=152d:0562:u";

}
