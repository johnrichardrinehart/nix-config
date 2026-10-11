{
  lib,
  writeShellApplication,
  replaceVars,
  python3,
  util-linux,
}:

writeShellApplication {
  name = "slicemk-update";
  runtimeInputs = [ util-linux ];
  text = ''
    exec ${python3}/bin/python3 ${
      replaceVars ./update.py { utilLinux = util-linux; }
    } ${./firmware/zmk-left.uf2} "$@"
  '';
  meta = {
    description = "Update the SliceMK ErgoDox 202207 Green left half firmware";
    platforms = lib.platforms.linux;
  };
}
