# Keyboards (darwin-modules/keyboard-remap).
#
# The user's macOS input source stays U.S. (default.nix). In the user's
# session the built-in keyboard types Dvorak through a device remap;
# external keyboards with Dvorak in their firmware (SliceMK, Moonlander)
# pass through unchanged. The remap acts below macOS's input sources, so
# QEMU and spicy forward Dvorak key codes to the guest, whose XKB layout is
# U.S. as well.
#
# Before login no remap can run: with FileVault, the first screen after a
# boot is the pre-boot unlock, which also logs in. It takes its layouts from
# the login window's input sources, so those are Dvorak by default with U.S.
# as the second choice (its input menu). That serves the built-in keyboard;
# a firmware-Dvorak keyboard needs U.S. picked there. The same holds at the
# login window after a logout, so the module's login window remap stays off
# (it would remap the built-in keyboard a second time).
{ config, lib, ... }:
let
  dvorak = {
    hyphen = "open_bracket";
    equal_sign = "close_bracket";
    q = "quote";
    w = "comma";
    e = "period";
    r = "p";
    t = "y";
    y = "f";
    u = "g";
    i = "c";
    o = "r";
    p = "l";
    open_bracket = "slash";
    close_bracket = "equal_sign";
    s = "o";
    d = "e";
    f = "u";
    g = "i";
    h = "d";
    j = "h";
    k = "t";
    l = "n";
    semicolon = "s";
    quote = "hyphen";
    z = "semicolon";
    x = "q";
    c = "j";
    v = "k";
    b = "x";
    n = "b";
    comma = "w";
    period = "v";
    slash = "z";
  };

  qemuPath = "^/nix/store/[0-9a-df-np-sv-z]{32}-qemu-[0-9][^/]*/bin/(\\.qemu-system-aarch64-wrapped|qemu-system-aarch64)$";

  inputSource =
    id: name:
    ''{ InputSourceKind = "Keyboard Layout"; "KeyboardLayout ID" = ${toString id}; "KeyboardLayout Name" = "${name}"; }'';
  dvorakSource = inputSource 16300 "Dvorak";
  usSource = inputSource 0 "U.S.";
  loginWindowPrefs = "/Library/Preferences/com.apple.HIToolbox";
in
{
  dev.johnrinehart.keyboardRemap = {
    enable = true;
    loginWindow = false;
    agentProgram = config.dev.johnrinehart.mbp-host.signedCopies.keyboard-remap.path;
    deviceRemaps = [
      {
        description = "Dvorak on the built-in keyboard";
        match."Built-In" = true;
        map = dvorak;
      }
    ];
    # QEMU's cocoa window has a menu whose Hide item takes Cmd+H. Spicy.app
    # has no menu and sends Cmd+H to the guest. The rule sees keys after the
    # Dvorak remap, so H is the built-in keyboard's physical J as well.
    appRules = [
      {
        description = "Swallow Cmd+H while QEMU's cocoa window is frontmost";
        frontmostApplication.filePaths = [ qemuPath ];
        key = "h";
        modifiers = {
          mandatory = [ "command" ];
          optional = [ "caps_lock" ];
        };
      }
    ];
  };

  # The login window's input sources, copied to the Preboot volume for the
  # FileVault unlock screen only when they change (updatePreboot takes a
  # few seconds).
  system.activationScripts.postActivation.text = lib.mkAfter ''
    echo "setting the login window's input sources (Dvorak, U.S.)..." >&2
    before=$(/sbin/md5 -q ${loginWindowPrefs}.plist 2>/dev/null || true)
    /usr/bin/defaults write ${loginWindowPrefs} AppleEnabledInputSources -array '${dvorakSource}' '${usSource}'
    /usr/bin/defaults write ${loginWindowPrefs} AppleSelectedInputSources -array '${dvorakSource}'
    /usr/bin/defaults write ${loginWindowPrefs} AppleCurrentKeyboardLayoutInputSourceID com.apple.keylayout.Dvorak
    if [[ $(/sbin/md5 -q ${loginWindowPrefs}.plist) != "$before" ]]; then
      echo "updating the Preboot volume for the FileVault unlock screen..." >&2
      /usr/sbin/diskutil apfs updatePreboot / >/dev/null
    fi
  '';
}
