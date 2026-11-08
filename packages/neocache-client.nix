{
  lib,
  nix,
  stdenv,
  writeShellApplication,
}:
let
  system = stdenv.hostPlatform.system;
  # app.neocache.io serves a tarball flake naming the newest complete static
  # client release in the public fuzzybear3965/neocache cache, for
  # x86_64-linux and aarch64-linux. `builtins.fetchClosure` copies it from
  # there, so this host must trust that cache's key (the neocache module's
  # default substitute caches include it).
  bootstrap = "tarball+https://app.neocache.io/bootstrap.nix";
in
writeShellApplication {
  name = "neocache";
  runtimeInputs = [ nix ];
  # Runs the current static client, resolved at start-up. The flake's packages
  # are fetchClosure store paths, not derivations, so `nix run` can't start
  # them; evaluating the attribute fetches the path.
  text = ''
    client="$(nix --extra-experimental-features 'nix-command flakes fetch-closure' \
      --tarball-ttl 86400 eval --raw ${lib.escapeShellArg "${bootstrap}#packages.${system}.default"})"
    exec "$client/bin/neocache" "$@"
  '';

  meta = {
    description = "Shell wrapper that runs the latest Neocache static client";
    mainProgram = "neocache";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  };
}
