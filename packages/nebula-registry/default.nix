{
  stdenv,
  lib,
  cjson,
  mbedtls,
  openssl,
}:
stdenv.mkDerivation {
  pname = "nebula-registry";
  version = "0.2.0";
  src = ./.;

  buildInputs = [
    cjson
    mbedtls
  ];
  nativeCheckInputs = [ openssl ];

  doCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;

  buildPhase = ''
    runHook preBuild
    # Embed page.html as a null-terminated C byte array so the binary is self-contained.
    {
      echo "static const unsigned char NR_PAGE_HTML[] = {"
      od -An -tx1 -v page.html | sed -E 's/([0-9a-f]{2})/0x\1,/g'
      echo "0x00 };"
    } > page_html.h

    "$CC" -O2 -Wall -Wextra -Werror -std=c11 \
      main.c registry.c dns.c server.c \
      -lcjson -lmbedtls -lmbedx509 -lmbedcrypto \
      -o nebula-registry
    runHook postBuild
  '';

  checkPhase = ''
    runHook preCheck
    "$CC" -O2 -Wall -Wextra -Werror -std=c11 -pthread \
      registry_test.c registry.c dns.c server.c \
      -lcjson -lmbedtls -lmbedx509 -lmbedcrypto \
      -o nebula-registry-test
    ./nebula-registry-test
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 nebula-registry "$out/bin/nebula-registry"
    runHook postInstall
  '';

  meta = {
    description = "Nebula lighthouse peer registry with liveness, DNS and an HTTPS peer view";
    license = lib.licenses.mit;
    mainProgram = "nebula-registry";
    platforms = lib.platforms.linux;
  };
}
