{ callPackage }:

callPackage ./slicemk-update/firmware.nix {
  config = ./slicemk-update/keyboard.json;
  snippets = [ "zmk-usb-logging" ];
}
