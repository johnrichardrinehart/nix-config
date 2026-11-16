{ lib, pkgs, ... }:
{
  # Every configuration, including those that enable Bluetooth without
  # dev.johnrinehart.bluetooth, uses the BlueZ from packages/bluez.nix.
  # Needs overlays.default for pkgs.dev.johnrinehart.
  hardware.bluetooth.package = lib.mkDefault pkgs.dev.johnrinehart.bluez;
}
