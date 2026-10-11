{
  lib,
  git,
  fetchurl,
  fetchpatch2,
  runtimeShellPackage,
}:
let
  gitVersion = "2.56.0";
in
git.overrideAttrs (old: {
  pname = "git-local-namespace";
  version = "${gitVersion}-local-namespace";

  src = fetchurl {
    url = "https://www.kernel.org/pub/software/scm/git/git-${gitVersion}.tar.xz";
    hash = "sha256-JsVsKWs4wGlbJvqV9HXx0BcE0tOOc0ZcowsLL13HidM=";
  };

  # Git 2.56.0 contains nixpkgs' darwin-unicode-filename-fix.patch (upstream
  # 1eb281159f0f) and osxkeychain-link-rust_lib.patch (upstream 522ea8ef7d85,
  # 87bd9bd40ee6). nixpkgs' t1517 patch does not apply to 2.56.0; t1517 is
  # disabled in preInstallCheck instead, as nixpkgs does since Git 2.55.0.
  patches =
    lib.filter (
      patch:
      !lib.elem (patch.name or (baseNameOf patch)) [
        "darwin-unicode-filename-fix.patch"
        "expect-gui--askyesno-failure-in-t1517.patch"
        "osxkeychain-link-rust_lib.patch"
      ]
    ) old.patches
    ++ [
      (fetchpatch2 {
        name = "git-local-namespace.patch";
        url = "https://github.com/johnrichardrinehart/git/compare/010afd3166ddc64c9863b1506f12cbcdda0d4ea1...08fb0de2c83ab27c651312c3a87e4ef7c2c62c00.patch?full_index=1";
        hash = "sha256-C5PCdH046LdNgsKccblHrvXDy/BczWB3JyTQ5nGMDDI=";
      })
    ];

  # Since Git 2.55.0, Rust is built unless NO_RUST is set; WITH_RUST is unused.
  # Native builds use Bash invoked as `sh` for SHELL_PATH: Git 2.56.0's t1017
  # relies on POSIX-mode behaviour (no word splitting of `>$path` redirection
  # targets), which Bash only enables under that name.
  makeFlags =
    map (
      flag:
      if lib.hasPrefix "SHELL_PATH=" flag then
        "SHELL_PATH=${lib.getExe' runtimeShellPackage "sh"}"
      else
        flag
    ) (lib.remove "WITH_RUST=YesPlease" old.makeFlags)
    ++ lib.optional (!lib.elem "WITH_RUST=YesPlease" old.makeFlags) "NO_RUST=YesPlease";

  # The test suite treats a non-empty $debug as --debug. With separateDebugInfo,
  # $debug is the debug output path, and the extra output breaks the test
  # harness on Git 2.55.0 and later.
  installCheckFlags = old.installCheckFlags ++ [ "debug=" ];

  # t1517 fails against an installed Git whenever `make install` adds a
  # command that the test does not list as an expected failure. t0050 and
  # t7527 depend on the build filesystem and fail on ZFS builders with formD
  # normalization, like the tests that nixpkgs already disables for ZFS.
  preInstallCheck = old.preInstallCheck + ''
    disable_test t1517-outside-repo
    disable_test t0050-filesystem
    disable_test t7527-builtin-fsmonitor
  '';

  meta = old.meta // {
    changelog = "https://github.com/git/git/blob/v${gitVersion}/Documentation/RelNotes/${gitVersion}.adoc";
  };
})
