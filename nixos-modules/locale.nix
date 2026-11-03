{ config, pkgs, ... }:
let
  # The SliceMK firmware types Dvorak itself: for a letter it sends the key
  # that a US layout maps to that letter. The console keymap, which applies
  # to every keyboard alike, then applied Dvorak a second time. This table
  # sends each such key back to the key position that Dvorak maps to the
  # letter, so the SliceMK reads like any QWERTY-positioned keyboard and
  # the console, tuigreet, the stage 1 prompt and Niri all use the one
  # Dvorak layout. It matches every ZMK board (1d50:615e), over USB (0003)
  # and Bluetooth (0005). Generated from the us and us(dvorak) key tables.
  zmkDvorakHwdb = ''
    evdev:input:b0003v1D50p615E*
    evdev:input:b0005v1D50p615E*
     KEYBOARD_KEY_70005=n
     KEYBOARD_KEY_70006=i
     KEYBOARD_KEY_70007=h
     KEYBOARD_KEY_70008=d
     KEYBOARD_KEY_70009=y
     KEYBOARD_KEY_7000a=u
     KEYBOARD_KEY_7000b=j
     KEYBOARD_KEY_7000c=g
     KEYBOARD_KEY_7000d=c
     KEYBOARD_KEY_7000e=v
     KEYBOARD_KEY_7000f=p
     KEYBOARD_KEY_70011=l
     KEYBOARD_KEY_70012=s
     KEYBOARD_KEY_70013=r
     KEYBOARD_KEY_70014=x
     KEYBOARD_KEY_70015=o
     KEYBOARD_KEY_70016=semicolon
     KEYBOARD_KEY_70017=k
     KEYBOARD_KEY_70018=f
     KEYBOARD_KEY_70019=dot
     KEYBOARD_KEY_7001a=comma
     KEYBOARD_KEY_7001b=b
     KEYBOARD_KEY_7001c=t
     KEYBOARD_KEY_7001d=slash
     KEYBOARD_KEY_7002d=apostrophe
     KEYBOARD_KEY_7002e=rightbrace
     KEYBOARD_KEY_7002f=minus
     KEYBOARD_KEY_70030=equal
     KEYBOARD_KEY_70033=z
     KEYBOARD_KEY_70034=q
     KEYBOARD_KEY_70036=w
     KEYBOARD_KEY_70037=e
     KEYBOARD_KEY_70038=leftbrace
  '';
in
{
  console.useXkbConfig = true;
  services.xserver.xkb.variant = "dvorak";
  time.timeZone = "America/New_York";

  services.udev.extraHwdb = zmkDvorakHwdb;

  # The same remap at the stage 1 passphrase prompt, for the SliceMK on its
  # cable: the hwdb and the rules that apply its key tables.
  boot.initrd.systemd.contents."/etc/udev/hwdb.bin".source =
    "${config.environment.etc."udev/hwdb.bin".source}";
  boot.initrd.services.udev.packages = [
    (pkgs.runCommand "initrd-evdev-rules" { } ''
      mkdir -p $out/lib/udev/rules.d
      for f in 60-input-id 60-evdev; do
        ln -s ${config.boot.initrd.systemd.package}/lib/udev/rules.d/$f.rules $out/lib/udev/rules.d
      done
    '')
  ];
}
