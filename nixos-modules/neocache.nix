{
  inputs,
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.neocache;
  tokenPath = config.sops.secrets.${cfg.tokenSecret}.path;
  stateDir = "/var/lib/neocache-push";
  # The hook writes each batch here first, then renames it into the queue, so
  # the pusher never reads a half-written batch.
  spoolDir = "${stateDir}/spool";
  queueDir = "${stateDir}/queue";
  profile = "push";
  toml = pkgs.formats.toml { };

  clientConfig = toml.generate "neocache.toml" {
    version = 1;
    default-server = cfg.server;
  };
  authConfig = toml.generate "auth.toml" {
    version = 1;
    servers.${cfg.server} = {
      default-profile = profile;
      profiles.${profile}.token-file = "/run/credentials/neocache-push.service/token";
    };
  };

  # The daemon runs this after every build and blocks its build loop until it
  # exits; a non-zero exit fails the build. So it only queues the outputs and
  # always succeeds; neocache-push.service uploads them.
  enqueue = pkgs.writeShellScript "neocache-push-enqueue" ''
    set -f
    [ -n "''${OUT_PATHS:-}" ] || exit 0
    tmp="$(${pkgs.coreutils}/bin/mktemp -p ${spoolDir})" &&
      printf '%s\n' $OUT_PATHS > "$tmp" &&
      ${pkgs.coreutils}/bin/mv "$tmp" ${queueDir}/ ||
      echo "neocache-push: failed to queue $OUT_PATHS" >&2
    exit 0
  '';

  push = pkgs.writeShellApplication {
    name = "neocache-push";
    runtimeInputs = [
      pkgs.coreutils
      cfg.package
    ];
    text = ''
      shopt -s nullglob
      config="$RUNTIME_DIRECTORY/config"
      cache="$RUNTIME_DIRECTORY/cache"
      install -D -m 0600 ${clientConfig} "$config/neocache/neocache.toml"
      install -D -m 0600 ${authConfig} "$cache/neocache/auth.toml"
      export XDG_CONFIG_HOME="$config" XDG_CACHE_HOME="$cache"

      batches=(${queueDir}/*)
      (( ''${#batches[@]} )) || exit 0

      # Paths garbage-collected since their build can no longer be pushed.
      paths=()
      while IFS= read -r path; do
        [[ -e $path ]] && paths+=("$path")
      done < <(sort -u "''${batches[@]}")

      if (( ''${#paths[@]} )); then
        printf '%s\n' "''${paths[@]}" | neocache push \
          --server ${lib.escapeShellArg cfg.server} \
          --namespace ${lib.escapeShellArg cfg.namespace} \
          --stdin \
          --output silent \
          ${lib.escapeShellArgs (lib.mapAttrsToList (k: v: "--tag=${k}=${v}") cfg.push.tags)} \
          ${lib.escapeShellArg cfg.cache}
      fi
      rm -f -- "''${batches[@]}"
    '';
  };
in
{
  options.dev.johnrinehart.neocache = {
    # neocache CI publishes the static client to the public
    # fuzzybear3965/neocache cache.
    package = lib.mkOption {
      type = lib.types.package;
      default = inputs.neocache.packages.${pkgs.stdenv.hostPlatform.system}.neocache-client-static;
      defaultText = lib.literalExpression "inputs.neocache.packages.\${system}.neocache-client-static";
    };

    server = lib.mkOption {
      type = lib.types.str;
      default = "https://cache.neocache.io";
    };

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "fuzzybear3965";
    };

    cache = lib.mkOption {
      type = lib.types.str;
      default = "fuzzybear3965";
    };

    tokenSecret = lib.mkOption {
      type = lib.types.str;
      default = "neocache-token";
      description = "sops secret holding a neocache token with fetch and push permission on the cache.";
    };

    substitute = {
      enable = lib.mkEnableOption "substituting from neocache caches in the system-wide Nix configuration";

      caches = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {
          "fuzzybear3965/fuzzybear3965" =
            "fuzzybear3965/fuzzybear3965:StrZW8zHX2REY32yQ/kRkuJCKlFdZ2/L+29KtohO+aE=";
          "fuzzybear3965/neocache" = "fuzzybear3965/neocache:U0v4rjSwUspr3wqEndwVH63e/HEVJZrtFWyGOB9l/jk=";
        };
        description = "Public keys of the substituted caches, keyed by `namespace/cache`.";
      };
    };

    push = {
      enable = lib.mkEnableOption "pushing every locally built store path to the neocache cache";

      tags = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default.hostname = config.networking.hostName;
        defaultText = lib.literalExpression "{ hostname = config.networking.hostName; }";
        description = "Tags attached to each pushed build output.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.substitute.enable {
      # Private caches authenticate the daemon with the token as the netrc
      # password for the server's host.
      sops.templates.nix-netrc.content = ''
        machine ${lib.removePrefix "https://" cfg.server}
        password ${config.sops.placeholder.${cfg.tokenSecret}}
      '';

      nix.settings = {
        extra-substituters = map (cache: "${cfg.server}/${cache}") (
          builtins.attrNames cfg.substitute.caches
        );
        extra-trusted-public-keys = builtins.attrValues cfg.substitute.caches;
        netrc-file = config.sops.templates.nix-netrc.path;
      };
    })

    (lib.mkIf cfg.push.enable {
      nix.settings.post-build-hook = enqueue;

      systemd.tmpfiles.rules = [
        "d ${stateDir} 0700 root root -"
        "d ${spoolDir} 0700 root root -"
        "d ${queueDir} 0700 root root -"
      ];

      systemd.paths.neocache-push = {
        description = "Push queued Nix build outputs to neocache";
        wantedBy = [ "paths.target" ];
        pathConfig.DirectoryNotEmpty = queueDir;
      };

      systemd.services.neocache-push = {
        description = "Push queued Nix build outputs to neocache";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        # A failed push leaves its batches queued; the auto-restart retries them
        # without the path unit re-triggering in a tight loop.
        startLimitIntervalSec = 0;
        # switch-to-configuration waits for a restarted oneshot, so a long
        # upload would block activation. The path unit starts it instead.
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe push;
          LoadCredential = "token:${tokenPath}";
          RuntimeDirectory = "neocache-push";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
          Restart = "on-failure";
          RestartSec = "1min";
        };
      };
    })
  ];
}
