{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.neocache;
  tokenPath = config.sops.secrets.${cfg.tokenSecret}.path;
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

  pushArgs = [
    "--server"
    cfg.server
    "--namespace"
    cfg.namespace
    "--watch"
    "--output"
    "line"
  ]
  ++ lib.mapAttrsToList (k: v: "--tag=${k}=${v}") cfg.push.tags
  ++ [ cfg.cache ];

  push = pkgs.writeShellApplication {
    name = "neocache-push";
    runtimeInputs = [
      pkgs.coreutils
      cfg.package
    ];
    text = ''
      config="$RUNTIME_DIRECTORY/config"
      install -D -m 0600 ${clientConfig} "$config/neocache/neocache.toml"
      install -D -m 0600 ${authConfig} "$CACHE_DIRECTORY/neocache/auth.toml"
      export XDG_CONFIG_HOME="$config"
      export XDG_CACHE_HOME="$CACHE_DIRECTORY"
      export XDG_STATE_HOME="$STATE_DIRECTORY"

      exec neocache push ${lib.escapeShellArgs pushArgs}
    '';
  };
in
{
  options.dev.johnrinehart.neocache = {
    # Resolves the current static client, which neocache CI publishes to the
    # public fuzzybear3965/neocache cache, through app.neocache.io at start-up.
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.dev.johnrinehart.neocache-client;
      defaultText = lib.literalExpression "pkgs.dev.johnrinehart.neocache-client";
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
      enable = lib.mkEnableOption "watching the Nix store and pushing every new store path to the neocache cache";

      tags = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default.hostname = config.networking.hostName;
        defaultText = lib.literalExpression "{ hostname = config.networking.hostName; }";
        description = "Tags attached to each pushed store path.";
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

      # Runs the latest static client from the public fuzzybear3965/neocache
      # cache, whose key the default `caches` above trust.
      environment.systemPackages = [ pkgs.dev.johnrinehart.neocache-client ];
    })

    (lib.mkIf cfg.push.enable {
      systemd.services.neocache-push = {
        description = "Watch the Nix store and push new store paths to neocache";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network-online.target"
          "nix-daemon.socket"
        ];
        wants = [
          "network-online.target"
          "nix-daemon.socket"
        ];
        # Keep retrying across offline periods and transient server errors.
        startLimitIntervalSec = 0;
        # The protected client stub ignores token-file in auth.toml and reads
        # this variable first. %d is the credentials directory.
        environment.NEOCACHE_CLIENT_TOKEN_FILE = "%d/token";
        serviceConfig = {
          Type = "simple";
          ExecStart = lib.getExe push;
          LoadCredential = "token:${tokenPath}";
          RuntimeDirectory = "neocache-push";
          RuntimeDirectoryMode = "0700";
          CacheDirectory = "neocache-push";
          CacheDirectoryMode = "0700";
          StateDirectory = "neocache-push";
          StateDirectoryMode = "0700";
          UMask = "0077";
          KillSignal = "SIGINT";
          Restart = "always";
          RestartSec = "30s";
        };
      };
    })
  ];
}
