{
  lib,
  stdenv,
  writeShellApplication,
  replaceVars,
  python3,
  util-linux,
  slicemk-firmware,
}:
let
  # Linux finds and mounts the drive with util-linux; macOS uses its own
  # diskutil and ioreg, so the Linux paths stay unsubstituted there.
  utilLinux = if stdenv.hostPlatform.isLinux then util-linux else null;
in
writeShellApplication {
  name = "slicemk-update";
  runtimeInputs = lib.optional stdenv.hostPlatform.isLinux util-linux;
  text = ''
    exec ${python3}/bin/python3 ${
      replaceVars ./update.py { inherit utilLinux; }
    } ${slicemk-firmware}/zmk.uf2 "$@"
  '';
  meta = {
    description = "Update the SliceMK ErgoDox 202207 Green left half firmware";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
