{ pkgs }:
let
  signer = pkgs.callPackage ../../packages/mycelium-tls { };
in
pkgs.runCommand "mycelium-tls-tests"
  {
    nativeBuildInputs = [
      signer
      pkgs.openssl
    ];
  }
  ''
    openssl req -new -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
      -nodes -subj /CN=Test-CA -days 2 -keyout ca.key -out ca.crt \
      -addext basicConstraints=critical,CA:TRUE \
      -addext keyUsage=critical,keyCertSign,cRLSign

    sign-mycelium-tls ca.crt ca.key lighthouse.mycelium.internal leaf alternate.mycelium.internal
    openssl verify -CAfile ca.crt -purpose sslserver -verify_hostname lighthouse.mycelium.internal leaf/server.crt
    openssl verify -CAfile ca.crt -purpose sslserver -verify_hostname alternate.mycelium.internal leaf/server.crt
    if openssl verify -CAfile ca.crt -verify_hostname stranger.mycelium.internal leaf/server.crt; then
      echo 'A server certificate must reject an unrelated hostname.' >&2
      exit 1
    fi
    test "$(stat -c %a leaf/server.key)" = 600
    test "$(stat -c %a leaf/server.crt)" = 644

    key_hash=$(sha256sum leaf/server.key)
    sign-mycelium-tls ca.crt ca.key lighthouse.mycelium.internal leaf
    test "$(sha256sum leaf/server.key)" = "$key_hash"
    openssl verify -CAfile ca.crt -verify_hostname lighthouse.mycelium.internal leaf/server.crt

    cert_hash=$(sha256sum leaf/server.crt)
    if sign-mycelium-tls ca.crt missing.key lighthouse.mycelium.internal leaf; then
      echo 'Certificate issuance must fail without the CA private key.' >&2
      exit 1
    fi
    test "$(sha256sum leaf/server.crt)" = "$cert_hash"
    test "$(sha256sum leaf/server.key)" = "$key_hash"
    touch $out
  ''
