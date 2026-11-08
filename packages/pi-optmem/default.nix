{
  fetchurl,
  lib,
  python3,
  stdenvNoCC,
}:
# OptMem: permanent, append-only agent memory. The npm package has no
# dependencies; its extension imports the pi API, which OMP provides.
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "pi-optmem";
  version = "1.0.0";

  src = fetchurl {
    url = "https://registry.npmjs.org/pi-optmem/-/pi-optmem-${finalAttrs.version}.tgz";
    hash = "sha512-xfMAaqIUUHOt3qr+EMechZ/kdK7NNoSW9qCeE2wNvP2gAaeiivMEK8hqmiFp26bcFj8Ult7BNo1PT56rEAeVkw==";
  };

  # The fixup phase points the shebang of `memo`, the storage engine that the
  # extension runs, at this Python.
  buildInputs = [ python3 ];

  dontBuild = true;

  # OMP loads lib/node_modules/pi-optmem as an extension through the "pi"
  # field of package.json. The store lives in ~/.optmem/memory, or in
  # $MEMORY_DIR when it is set.
  installPhase = ''
    runHook preInstall

    pkgRoot="$out/lib/node_modules/pi-optmem"
    mkdir -p "$pkgRoot" "$out/bin"
    cp -r . "$pkgRoot"
    ln -s "$pkgRoot/memo" "$out/bin/memo"

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    MEMORY_DIR="$TMPDIR/optmem-check" "$out/bin/memo" init
    MEMORY_DIR="$TMPDIR/optmem-check" "$out/bin/memo" note "install check"
    MEMORY_DIR="$TMPDIR/optmem-check" "$out/bin/memo" recall "install check" | grep -q "install check"

    runHook postInstallCheck
  '';

  meta = {
    description = "Permanent, append-only memory for pi and OMP agents";
    homepage = "https://github.com/pi-pod/pi-optmem";
    # Upstream publishes no license.
    mainProgram = "memo";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})
