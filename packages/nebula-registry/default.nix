{
  lib,
  python3,
  writeShellApplication,
}:
let
  python = python3.withPackages (ps: [ ps.dnslib ]);
in
writeShellApplication {
  name = "nebula-registry";
  text = ''
    exec ${lib.getExe python} ${./nebula_registry.py} "$@"
  '';
  passthru = { inherit python; };
  meta = {
    description = "Nebula lighthouse peer registry with liveness, DNS and an HTTPS peer view";
    license = lib.licenses.mit;
    mainProgram = "nebula-registry";
    platforms = lib.platforms.linux;
  };
}
