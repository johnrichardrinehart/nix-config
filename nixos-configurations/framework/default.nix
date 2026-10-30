{ config, pkgs, ... }:
{
  imports = [
    ./framie.nix
    ./framework.nix
    ./git-send-email.nix
    ./nebula.nix
    ./share-webdav.nix
    ./tailscale-nix-builders.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  dev.johnrinehart.boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 5;
  };

  boot.loader = {
    efi.canTouchEfiVariables = true;
    timeout = 1;
  };

  dev.johnrinehart.profiles.framework.enable = true;

  dev.johnrinehart.firmware.framework-ec.features = [ "F9-display-toggle" ];
  dev.johnrinehart.firmware.framework-ec.flashService.enable = true;

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
