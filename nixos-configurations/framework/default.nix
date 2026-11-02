{ config, pkgs, ... }:
{
  imports = [
    ./framie.nix
    ./framework.nix
    ./git-send-email.nix
    ./nebula.nix
    ./neocache.nix
    ./share-webdav.nix
    ./tailscale-nix-builders.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  # Kernels and initrds live on the 3 GiB XBOOTLDR partition (/boot); the
  # ESP (/efi, a 510 MiB file system) holds systemd-boot only. Each
  # maintenance initrd takes 230 MB.
  dev.johnrinehart.boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 3;
  };

  boot.loader = {
    efi.canTouchEfiVariables = true;
    efi.efiSysMountPoint = "/efi";
    systemd-boot.xbootldrMountPoint = "/boot";
    timeout = 1;
  };

  dev.johnrinehart.profiles.framework.enable = true;

  dev.johnrinehart.firmware.framework-ec.features = [ "F9-display-toggle" ];
  dev.johnrinehart.firmware.framework-ec.flashService.enable = true;

  # `root-shell` opens a root shell without a password for root and wheel
  # members (nixos-modules/tmux-root-shell.nix).
  dev.johnrinehart.tmux.rootShell.enable = true;

  # The boot menu editor is on, so physical access can already change the
  # kernel command line. The maintenance shell therefore asks for no
  # password; the LUKS passphrase still guards root and swap.
  dev.johnrinehart.maintenanceInitrd = {
    enable = true;
    emergencyAccess = true;
    # The AX210 (ty-a0-gf-a0); iwlwifi loads iwlmvm on request.
    wifiKernelModules = [
      "iwlwifi"
      "iwlmvm"
    ];
  };

  # The built-in camera has no infrared sensor, so a photo can pass for a
  # face. The check can only reject an attempt. The password is always required.
  dev.johnrinehart.desktop.greetd_niri.face = {
    enable = true;
    device = "/dev/v4l/by-id/usb-Generic_Laptop_Camera_200901010001-video-index0";
    inputFormat = "mjpeg";
  };

  dev.johnrinehart.desktop.greetd_niri.niri.extraConfig = ''
    output "eDP-1" {
        mode "1920x1200@60.001"
        scale 1.0
        transform "normal"
        position x=3840 y=1800
    }
  '';

  environment.systemPackages = [
    pkgs.intel-gpu-tools
  ];

  # iwlwifi with debugfs and the requested scan dwell honoured, built out of
  # tree against this kernel (packages/iwlwifi).
  boot.extraModulePackages = [
    (pkgs.dev.johnrinehart.iwlwifi.override {
      inherit (config.boot.kernelPackages) kernel kernelModuleMakeFlags;
    })
  ];
}
