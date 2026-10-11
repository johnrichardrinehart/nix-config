{
  writeShellApplication,
  coreutils,
  openssl,
}:
writeShellApplication {
  name = "sign-mycelium-tls";
  runtimeInputs = [
    coreutils
    openssl
  ];
  text = builtins.readFile ./sign-mycelium-tls.sh;
}
