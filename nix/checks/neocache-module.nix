{
  inputs,
  lib,
  pkgs,
}:
let
  mockNeocache = pkgs.writeShellScriptBin "neocache" ''
    set -euo pipefail
    printf 'XDG_CONFIG_HOME=%s\n' "$XDG_CONFIG_HOME" > "$TEST_OUT/env"
    printf 'XDG_CACHE_HOME=%s\n' "$XDG_CACHE_HOME" >> "$TEST_OUT/env"
    printf 'XDG_STATE_HOME=%s\n' "$XDG_STATE_HOME" >> "$TEST_OUT/env"
    printf '%s\n' "$@" > "$TEST_OUT/args"
  '';

  evaluated = lib.nixosSystem {
    specialArgs = { inherit inputs; };
    modules = [
      inputs.sops-nix.nixosModules.sops
      ../../nixos-modules/neocache.nix
      {
        nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
        system.stateVersion = "24.05";
        networking.hostName = "framie";
        sops.secrets.neocache-token.path = "/run/secrets/neocache-token";

        dev.johnrinehart.neocache = {
          package = mockNeocache;
          push.enable = true;
        };
      }
    ];
  };

  cfg = evaluated.config;
  service = cfg.systemd.services.neocache-push;
in
assert !(cfg.nix.settings ? post-build-hook);
assert !(cfg.systemd.paths ? neocache-push);
assert service.wantedBy == [ "multi-user.target" ];
assert builtins.elem "network-online.target" service.after;
assert builtins.elem "nix-daemon.socket" service.after;
assert builtins.elem "network-online.target" service.wants;
assert builtins.elem "nix-daemon.socket" service.wants;
assert service.startLimitIntervalSec == 0;
assert service.environment.NEOCACHE_CLIENT_TOKEN_FILE == "%d/token";
assert service.serviceConfig.Type == "simple";
assert service.serviceConfig.LoadCredential == "token:/run/secrets/neocache-token";
assert service.serviceConfig.RuntimeDirectory == "neocache-push";
assert service.serviceConfig.CacheDirectory == "neocache-push";
assert service.serviceConfig.StateDirectory == "neocache-push";
assert service.serviceConfig.KillSignal == "SIGINT";
assert service.serviceConfig.Restart == "always";
pkgs.runCommand "neocache-module-check" { } ''
    set -euo pipefail
    work="$(mktemp -d)"
    export RUNTIME_DIRECTORY="$work/runtime"
    export CACHE_DIRECTORY="$work/cache"
    export STATE_DIRECTORY="$work/state"
    export TEST_OUT="$work/out"
    mkdir -p "$RUNTIME_DIRECTORY" "$CACHE_DIRECTORY" "$STATE_DIRECTORY" "$TEST_OUT"

    ${service.serviceConfig.ExecStart}

    expected_args="$(cat <<'EOF'
  push
  --server
  https://cache.neocache.io
  --namespace
  fuzzybear3965
  --watch
  --output
  line
  --tag=hostname=framie
  fuzzybear3965
  EOF
    )"
    diff -u <(printf '%s\n' "$expected_args") "$TEST_OUT/args"

    grep -Fx "XDG_CONFIG_HOME=$RUNTIME_DIRECTORY/config" "$TEST_OUT/env"
    grep -Fx "XDG_CACHE_HOME=$CACHE_DIRECTORY" "$TEST_OUT/env"
    grep -Fx "XDG_STATE_HOME=$STATE_DIRECTORY" "$TEST_OUT/env"

    grep -Fq 'default-server = "https://cache.neocache.io"' "$RUNTIME_DIRECTORY/config/neocache/neocache.toml"
    grep -Fq 'token-file = "/run/credentials/neocache-push.service/token"' "$CACHE_DIRECTORY/neocache/auth.toml"

    touch "$out"
''
