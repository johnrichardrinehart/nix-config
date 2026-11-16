{
  lib,
  fetchurl,
  bluez,
}:

# BlueZ 5.88 moves HID over GATT to src/shared/hog.c, which reads the Report
# Map and the Report Reference descriptors again on every reconnection. Up to
# 5.87, a failed read of either one is never retried while bluetoothd runs, so
# a keyboard that reset mid-connection stays connected without an input
# device until bluetoothd is restarted.
bluez.overrideAttrs (
  finalAttrs: old: {
    version = "5.88";

    src = fetchurl {
      url = "mirror://kernel/linux/bluetooth/bluez-${finalAttrs.version}.tar.xz";
      hash = "sha256-aVLDnrX4sO5xLMUKs7z/A74XxBDdl8pkD0hJ2aFlO6M=";
    };

    # 5.88 already contains the bluetoothctl non-interactive fixes that
    # nixpkgs applies to 5.86, and nixpkgs' lreadline.patch no longer applies.
    patches =
      lib.filter (
        patch:
        let
          name = patch.name or (baseNameOf patch);
        in
        !(lib.hasPrefix "fix-btctl-noninteractive-regression" name || name == "lreadline.patch")
      ) old.patches
      ++ [ ../patches/bluez-lreadline.patch ];

    # 5.88 removed the deprecated gatttool (a7da60ed4).
    postInstall =
      lib.replaceStrings [ "install -Dm755 attrib/gatttool $out/bin/gatttool\n" ] [ "" ]
        old.postInstall;
  }
)
