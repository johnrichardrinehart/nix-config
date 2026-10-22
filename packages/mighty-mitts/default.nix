# Mighty Mitts: a menu bar item showing the left and right battery levels of a
# ZMK split keyboard that reports its peripheral's level through a second
# Battery Service (CONFIG_ZMK_SPLIT_BLE_CENTRAL_BATTERY_LEVEL_PROXY).
#
# Built from source with nixpkgs' clang rather than Xcode. The upstream
# release is signed only with an Apple Development certificate, so
# Gatekeeper rejects it. The build is a single executable rather than an
# .app: the app has no nib or assets, and its Info.plist (which carries the
# Bluetooth usage description macOS requires before it lets a program use
# CoreBluetooth) is embedded in the binary's __TEXT,__info_plist section.
# That lets the Mac host run it as a signed copy at a fixed path
# (darwin-configurations/mbp-host/signed-copies.nix), so the Bluetooth grant
# survives rebuilds.
{
  lib,
  stdenv,
  fetchFromGitHub,
}:
let
  infoPlist = builtins.toFile "mighty-mitts-Info.plist" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleIdentifier</key>
      <string>mighty-mitts</string>
      <key>CFBundleName</key>
      <string>Mighty Mitts</string>
      <key>CFBundleShortVersionString</key>
      <string>2.0</string>
      <key>LSUIElement</key>
      <true/>
      <key>NSBluetoothAlwaysUsageDescription</key>
      <string>Mighty Mitts reads the battery level of each half of a split keyboard.</string>
    </dict>
    </plist>
  '';
in
stdenv.mkDerivation {
  pname = "mighty-mitts";
  version = "2.0";

  src = fetchFromGitHub {
    owner = "codyd51";
    repo = "Mighty-Mitts";
    # Tag v2.0, the head of the release branch.
    rev = "75da8660599d6cc1e65de7c9cb300d560f855c98";
    hash = "sha256-vqhhjiH+uD15wEO2UqMjuHB5oseAJUt8QCudXUDUZUI=";
  };

  buildPhase = ''
    runHook preBuild
    $CC -O2 -fobjc-arc -fobjc-weak \
      "Mighty Mitts/main.m" "Mighty Mitts/AppDelegate.m" \
      -framework Cocoa -framework CoreBluetooth -framework QuartzCore \
      -Wl,-sectcreate,__TEXT,__info_plist,${infoPlist} \
      -o mighty-mitts
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 mighty-mitts "$out/bin/mighty-mitts"
    runHook postInstall
  '';

  meta = {
    description = "Menu bar battery levels for both halves of a ZMK split keyboard";
    homepage = "https://github.com/codyd51/Mighty-Mitts";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
    mainProgram = "mighty-mitts";
  };
}
