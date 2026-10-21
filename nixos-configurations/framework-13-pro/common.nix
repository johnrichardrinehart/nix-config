# Framework Laptop 13 Pro, AMD Ryzen AI 9 HX 370 mainboard (Radeon 890M,
# 2x48 GB DDR5-5600, MediaTek MT7925 Wi-Fi/Bluetooth): everything the
# installed system (`framework-13-pro`) and the netbooted one
# (`framework-13-pro-netboot`) share.
#
# Framework's desktop and userspace come from profiles.framework, shared with
# `framework` (framie); the work layer is added downstream, as it is for the
# `mbp-apple-silicon` guest.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    inputs.nixos-hardware.nixosModules.framework-amd-ai-300-series
    ./hardware.nix
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  networking.hostName = "framework-13-pro";

  dev.johnrinehart.profiles.framework.enable = true;

  dev.johnrinehart.network = {
    enable = true;
    manager = "networkmanager";
  };

  # 13.5" 2880x1920 touch panel, 30-120 Hz. 1.5 leaves a 1920x1280 logical
  # desktop, about what framie's panel shows at 1.0. Mode is left to the
  # panel's preferred timing.
  dev.johnrinehart.desktop.greetd_niri.niri.extraConfig = ''
    output "eDP-1" {
        scale 1.5
        transform "normal"
        position x=3840 y=1800
        variable-refresh-rate on-demand=true
    }
  '';

  # Nothing to hibernate to: neither system has swap.
  dev.johnrinehart.system.suspendVerb = "suspend";
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandlePowerKey = "suspend";
    HandleSuspendKey = "suspend";
  };

  # Rank the built-in microphone below the Samson Q9U (profiles.framework).
  # Ryzen AI 300 exposes its analog codec as a generic HD-Audio card.
  dev.johnrinehart.sound.rnnoise.inputRules = [
    {
      matches = [
        {
          "media.class" = "Audio/Source";
          "api.alsa.card.name" = "HD-Audio Generic";
        }
      ];
      actions.update-props = {
        "priority.session" = 2200;
      };
    }
  ];

  # OpenVINO's GPU device is Intel graphics only; ONNX Runtime's own CPU
  # provider runs the dictation models on the Zen 5 cores.
  dev.johnrinehart.voice-dictation.executionProviders = {
    audio.provider = "cpu";
    decoder.provider = "cpu";
  };

  # As on the mbp-apple-silicon guest: omp comes from llm-agents.nix, which
  # numtide prebuilds; without the cache every new version builds locally.
  nix.settings.extra-substituters = [ "https://cache.numtide.com" ];
  nix.settings.extra-trusted-public-keys = [
    "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
  ];

  # The netbooted system rebuilds /etc/shadow in RAM on every boot, so the
  # account needs a declared password to log in at the greeter at all; the
  # installed one takes it only when the account is first created. Like the
  # guest's, it lands in the world-readable store, so SSH accepts keys only.
  users.users.${config.dev.johnrinehart.users.primary}.initialPassword = "john";
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
    PermitRootLogin = lib.mkForce "prohibit-password";
  };

  environment.systemPackages = [
    pkgs.amdgpu_top
  ];
}
