let
  builtInKeyboard = {
    identifiers = [ { is_built_in_keyboard = true; } ];
    type = "device_if";
  };

  dvorakMap = {
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

  dvorakManipulator = from: to: {
    conditions = [ builtInKeyboard ];
    from = {
      key_code = from;
      modifiers.optional = [ "any" ];
    };
    to = [ { key_code = to; } ];
    type = "basic";
  };

  qemuPath = "^/nix/store/[0-9a-df-np-sv-z]{32}-qemu-[0-9][^/]*/bin/(\\.qemu-system-aarch64-wrapped|qemu-system-aarch64)$";
  qemuManipulator = keyCode: deviceCondition: {
    conditions = [
      {
        file_paths = [ qemuPath ];
        type = "frontmost_application_if";
      }
      (builtInKeyboard // { type = deviceCondition; })
    ];
    from = {
      key_code = keyCode;
      modifiers = {
        mandatory = [ "command" ];
        optional = [ "caps_lock" ];
      };
    };
    to = [ { key_code = "vk_none"; } ];
    type = "basic";
  };
in
{
  profiles = [
    {
      complex_modifications.rules = [
        {
          description = "Swallow Cmd+H when QEMU's cocoa window is frontmost";
          manipulators = [
            (qemuManipulator "j" "device_if")
            (qemuManipulator "h" "device_unless")
          ];
        }
        {
          description = "Use Dvorak on the built-in keyboard";
          manipulators = builtins.map (from: dvorakManipulator from dvorakMap.${from}) (
            builtins.attrNames dvorakMap
          );
        }
      ];
      name = "Default profile";
      selected = true;
      virtual_hid_keyboard.keyboard_type_v2 = "ansi";
    }
  ];
}
