# Ryzen AI 300 mainboard in the 13 Pro chassis. nixos-hardware's
# framework-amd-ai-300-series module (imported by default.nix) covers the
# board; this file adds what it does not. The Pro chassis parts (haptic
# touchpad, touch panel, 74 Wh battery, speakers) need BIOS 4.02 or later.
{ config, pkgs, ... }:
{
  # Linux 7.3 or later. 7.3 carries the amdgpu DCN vblank/flip rework that
  # fixes flip_done timeouts and freezes on Strix Point, including the 13 Pro
  # AMD, and Replay fixes for this panel (black eDP after DPMS, tearing
  # flips). The WisdPi card's RTL8159 needs 7.2 at least.
  #
  # https://community.frame.work/t/framework-13-pro-fedora-44-frequent-system-freezes/85040
  boot.kernelPackages = pkgs.linuxPackages_latest;

  boot.kernelModules = [ "kvm-amd" ];

  # The 890M's VRAM carve-out is 512 MiB; everything else it reaches is GTT,
  # which TTM caps at half of RAM (46.8 GiB). Vulkan reports carve-out + GTT
  # as the device's memory, so the cap is the largest model llama.cpp can
  # offload. 80 GiB (in 4 KiB pages) fits a ~47 GB MoE plus KV cache and
  # leaves ~13 GiB for the desktop. A cap, not a reservation: GTT pages are
  # allocated on demand.
  boot.kernelParams = [ "ttm.pages_limit=20971520" ];

  # The lid and power button can come up with wakeup disabled, so the machine
  # sleeps but only a long press of the power button wakes it.
  # https://github.com/NixOS/nixos-hardware/issues/1782#issuecomment-6254883883
  services.udev.extraRules = ''
    KERNEL=="PNP0C0C:00", SUBSYSTEM=="platform", DRIVER=="acpi-button", ATTR{power/wakeup}="enabled"
    KERNEL=="PNP0C0D:00", SUBSYSTEM=="platform", DRIVER=="acpi-button", ATTR{power/wakeup}="enabled"
  '';

  # MT7925: without a regulatory domain the card stays on the conservative
  # world domain and loses throughput.
  hardware.wirelessRegulatoryDatabase = true;
  boot.extraModprobeConfig = ''
    options cfg80211 ieee80211_regdom="US"
  '';

  # MT7925 driver fixes, built out of tree against this kernel so a change
  # needs no kernel rebuild (packages/mt76).
  boot.extraModulePackages = [
    (pkgs.dev.johnrinehart.mt76.override {
      inherit (config.boot.kernelPackages) kernel kernelModuleMakeFlags;
    })
  ];
}
