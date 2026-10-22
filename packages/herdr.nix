{
  lib,
  callPackage,
  fetchFromGitHub,
  rustPlatform,
  zig_0_16,
}:
rustPlatform.buildRustPackage rec {
  pname = "herdr";
  version = "0.9.5";

  src = fetchFromGitHub {
    owner = "herdrdev";
    repo = "herdr";
    tag = "v${version}";
    hash = "sha256-N7e7oCKxeCoxek6UT8Lweq16rSsQQi34QMb7C2iNpm8=";
  };

  cargoHash = "sha256-a6DgQodo+qa5yg/d+yMfsM9EUv2LQRFrqZgmwgVxggE=";

  zigDeps = callPackage "${src}/vendor/libghostty-vt/build.zig.zon.nix" {
    name = "${pname}-${version}-zig-cache";
  };

  preBuild = ''
    # Keep zig out of nativeBuildInputs: its setup hook selects `zig build`,
    # while herdr is a Cargo project that only needs Zig 0.16 during build scripts.
    export PATH="${lib.getBin zig_0_16}/bin:$PATH"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
    export LIBGHOSTTY_VT_ZIG_SYSTEM_DIR="${zigDeps}"
  '';

  # The upstream test suite includes real PTY/foreground-process integration
  # tests that can hang under the remote Nix builder.
  doCheck = false;

  meta = {
    description = "Agent multiplexer that lives in your terminal";
    homepage = "https://github.com/herdrdev/herdr";
    license = lib.licenses.agpl3Plus;
    mainProgram = "herdr";
    maintainers = [ ];
  };
}
