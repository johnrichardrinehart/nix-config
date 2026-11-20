{
  bun,
  cargo,
  fetchurl,
  lib,
  makeWrapper,
  nodejs,
  rustc,
  stdenvNoCC,
}:
# The npm package bundles all of its dependencies, so it needs no npm install.
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "context-mode";
  version = "2.2.1";

  src = fetchurl {
    url = "https://registry.npmjs.org/context-mode/-/context-mode-${finalAttrs.version}.tgz";
    hash = "sha256-LoIwmnZFupDyv6R+l4XkwK5g/kfuKhydG/bm9dmGtI4=";
  };

  nativeBuildInputs = [ makeWrapper ];

  dontBuild = true;

  # OMP loads lib/node_modules/context-mode as an extension through the "pi"
  # field of package.json.
  installPhase = ''
    runHook preInstall

    pkgRoot="$out/lib/node_modules/context-mode"
    mkdir -p "$pkgRoot"
    cp -r . "$pkgRoot"
    makeWrapper ${lib.getExe nodejs} "$out/bin/context-mode" \
      --add-flags "$pkgRoot/cli.mjs"

    runHook postInstall
  '';

  passthru.ompRuntimeInputs = [
    bun
    cargo
    rustc
  ];

  meta = {
    description = "MCP plugin that reduces coding-agent context use";
    homepage = "https://github.com/mksglu/context-mode";
    license = lib.licenses.elastic20;
    mainProgram = "context-mode";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})
