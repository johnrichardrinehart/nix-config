{
  buildNpmPackage,
  bun,
  cargo,
  fetchurl,
  lib,
  pkg-config,
  python3,
  rustc,
}:
buildNpmPackage rec {
  pname = "context-mode";
  version = "1.0.169";

  src = fetchurl {
    url = "https://registry.npmjs.org/context-mode/-/context-mode-${version}.tgz";
    hash = "sha512-94JIaFuLjF9SO2BsGTrbGtyT44K95+9OC8BdbaL/UT76xOkanJLfUR5CzmNw+GELXZQqH4nBrKg9wjBnSFkVnQ==";
  };

  npmDepsHash = "sha256-tfuaTp3XeASjPIpGSgTBE6GAZbqE4kA7fj11Z8NbE8Q=";

  nativeBuildInputs = [
    pkg-config
    python3
  ];
  postPatch = ''
    sed -i '/"scripts": {/,/^  },$/d' package.json
    sed -i '/"devDependencies": {/,/^  },$/d' package.json
    cp ${./package-lock.json} package-lock.json
  '';

  dontNpmBuild = true;

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
}
