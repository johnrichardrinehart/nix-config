{ callPackage }:

callPackage ./slicemk-update/firmware.nix {
  config = ./slicemk-update/dongle.json;
  board = "raytac_mdbt50q_cx_blue";
  shield = "slicemk_ergodox_dongle";
  snippets = [ "zmk-usb-logging" ];
}
