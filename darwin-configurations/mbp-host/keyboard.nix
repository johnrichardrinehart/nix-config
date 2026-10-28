# Keyboards (darwin-modules/keyboard-remap).
#
# macOS stays on U.S. (default.nix). The built-in keyboard types Dvorak
# through a device remap, from the login window on; external keyboards with
# Dvorak in their firmware (SliceMK, Moonlander) pass through unchanged. The
# remap acts below macOS's input sources, so QEMU and spicy forward Dvorak
# key codes to the guest, whose XKB layout is U.S. as well. FileVault's
# pre-boot unlock runs before any of this and stays U.S.
{ config, lib, ... }:
let
  user = config.system.primaryUser;

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

  karabiner = "/Library/Application Support/org.pqrs/Karabiner-Elements";
  karabinerAgents = "${karabiner}/Karabiner-Elements Non-Privileged Agents v2.app/Contents/MacOS/Karabiner-Elements Non-Privileged Agents v2";
in
{
  dev.johnrinehart.keyboardRemap = {
    enable = true;
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

  # keyboard-remap replaces Karabiner-Elements, whose driver extension device
  # management now denies. Remove an installation the way Karabiner's own
  # uninstaller does: its agents are unregistered as the user, then
  # uninstall.sh removes the apps, daemons and driver files as root.
  system.activationScripts.postActivation.text = lib.mkAfter ''
    if [[ -f ${lib.escapeShellArg karabiner}/uninstall.sh ]]; then
      echo "removing Karabiner-Elements..." >&2
      /bin/launchctl asuser "$(/usr/bin/id -u ${user})" /usr/bin/sudo -u ${user} \
        ${lib.escapeShellArg karabinerAgents} unregister-core-agents || true
      for daemon in Karabiner-Core-Service Karabiner-VirtualHIDDevice-Daemon; do
        /bin/launchctl bootout "system/org.pqrs.service.daemon.$daemon" 2>/dev/null || true
      done
      /bin/bash ${lib.escapeShellArg karabiner}/uninstall.sh || true
    fi
  '';
}
