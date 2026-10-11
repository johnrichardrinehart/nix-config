{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.agentTools;
  mkMergedCodexConfig =
    {
      name,
      layers,
    }:
    pkgs.dev.johnrinehart.codex-config-merged.override {
      inherit name layers;
      header = codexMergedConfigHeader;
    };

  codexMergedConfigHeader = pkgs.writeText "codex-config-header.toml" ''
    # Managed by JohnOS. User and project Codex config layers may still override
    # these defaults when needed.
    #
    # Unix socket permissions are supported by codex-cli 0.130.0 via
    # openai/codex dd30c8eedd171d2dda71c43fac27dc42f457da5f (#15120).

  '';

  codexPluginTopLevelConfig = lib.optionalString (cfg.codexCli.statusLinePlugins != [ ]) ''
    [dev.johnrinehart.agentTools.codexCli]
    statusLinePlugins = ${builtins.toJSON cfg.codexCli.statusLinePlugins}
  '';

  codexSystemTopLevelConfig = ''
    # Managed by JohnOS. User and project Codex config layers may still override
    # these defaults when needed.

    sandbox_mode = "workspace-write"
    suppress_unstable_features_warning = true

    [tui]
    status_line = [
      "model-with-reasoning",
      "git-branch",
      "context-remaining",
      "total-input-tokens",
      "total-output-tokens",
      "weekly-limit",
    ]
  ''
  + codexPluginTopLevelConfig;

  codexPermissionsConfig = ''
    default_permissions = "johnos-workspace"

    [permissions.johnos-workspace.filesystem]
    ":root" = "read"
    ":project_roots" = "write"
    ":tmpdir" = "write"
    "/tmp" = "write"

    [permissions.johnos-workspace.network]
    enabled = true

    [permissions.johnos-workspace.network.unix_sockets]
    "/nix/var/nix/daemon-socket/socket" = "allow"
  '';
  codexSystemTopLevelFile = pkgs.writeText "codex-system-top-level.toml" codexSystemTopLevelConfig;
  codexPermissionsFile = pkgs.writeText "codex-permissions.toml" codexPermissionsConfig;
  codexMergedConfig = mkMergedCodexConfig {
    name = "codex-config-merged.toml";
    layers = [
      codexSystemTopLevelFile
    ]
    ++ cfg.codexCli.configLayers
    ++ [
      codexPermissionsFile
    ];
  };
in
{
  options.dev.johnrinehart.agentTools = {
    enable = lib.mkEnableOption "agent-oriented local AI tooling";

    "oh-my-codex".enable =
      lib.mkEnableOption "oh-my-codex multi-agent orchestration layer for Codex CLI";

    pi = {
      enable = lib.mkEnableOption "Pi coding agent";
      createWheelUser = lib.mkEnableOption "a dedicated pi user with wheel access";
    };

    omp = {
      enable = lib.mkEnableOption "OMP coding agent";

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.dev.johnrinehart.omp.withPlugins (plugins: [ plugins.context-mode ]);
        defaultText = lib.literalExpression "pkgs.dev.johnrinehart.omp.withPlugins (plugins: [ plugins.context-mode ])";
        description = ''
          OMP package installed system-wide. Home Manager points agent-deck's
          built-in `omp` tool at this package so both launch the same binary.
        '';
      };
    };

    primeAgent = {
      enable = lib.mkEnableOption "Prime Agent";
      createWheelUser = lib.mkEnableOption "a dedicated prime-agent user with wheel access";
    };

    codexCli = {
      enable = lib.mkEnableOption "Codex CLI";
      createWheelUser = lib.mkEnableOption "a dedicated codex user with wheel access";

      statusLinePlugins = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        example = [ "codex-weekly-pace" ];
        description = ''
          Status-line plugin names to expose in the system Codex config layer.
          When this contains "codex-weekly-pace", the corresponding helper
          package is installed into systemPackages.
        '';
      };

      configLayers = lib.mkOption {
        type = with lib.types; listOf path;
        default = [ ];
        description = ''
          Additional Codex config.toml layers to merge between the base system
          layer and sandbox layer. Submodules can publish configuration here.
        '';
      };

      hooksSource = lib.mkOption {
        type = with lib.types; nullOr path;
        default = null;
        description = ''
          Optional hooks.json source published by a submodule.
        '';
      };
    };

    claudeCodeCli = {
      enable = lib.mkEnableOption "Claude Code CLI";
      createWheelUser = lib.mkEnableOption "a dedicated claude user with wheel access";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      dev.johnrinehart.agentTools = {
        pi.enable = lib.mkDefault true;
        omp.enable = lib.mkDefault true;
        primeAgent.enable = lib.mkDefault true;
        codexCli.enable = lib.mkDefault true;
        claudeCodeCli.enable = lib.mkDefault true;
      };

      environment.systemPackages = [
        pkgs.dev.johnrinehart.agent-deck
        pkgs.dev.johnrinehart.herdr
      ];
    })
    (lib.mkIf cfg.pi.enable {
      environment.systemPackages = [ pkgs.dev.johnrinehart.pi-nix ];
    })
    (lib.mkIf cfg.omp.enable {
      dev.johnrinehart.nix.allowedUnfreePackages = lib.mkAfter [ "context-mode" ];
      environment.systemPackages = [ cfg.omp.package ];
    })
    (lib.mkIf (cfg.pi.enable && cfg.pi.createWheelUser) {
      users.users.pi = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
      };
    })
    (lib.mkIf cfg.primeAgent.enable {
      environment.systemPackages = [ pkgs.dev.johnrinehart.prime-agent-nix ];
    })
    (lib.mkIf (cfg.primeAgent.enable && cfg.primeAgent.createWheelUser) {
      users.users."prime-agent" = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
      };
    })
    (lib.mkIf cfg.codexCli.enable {
      environment.systemPackages = [ pkgs.dev.johnrinehart.codex-cli-nix ];

      # Always publish a system Codex config layer when Codex CLI is enabled,
      # even when OMX is disabled.
      environment.etc."codex/config.toml".source = codexMergedConfig;
    })
    (lib.mkIf (cfg.codexCli.enable && cfg.codexCli.createWheelUser) {
      users.users.codex = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
      };
    })
    (lib.mkIf (cfg.codexCli.enable && lib.elem "codex-weekly-pace" cfg.codexCli.statusLinePlugins) {
      environment.systemPackages = [ pkgs.dev.johnrinehart.codex-weekly-pace ];
    })
    (lib.mkIf cfg.claudeCodeCli.enable {
      environment.systemPackages = [ pkgs.dev.johnrinehart.claude-code-nix ];
    })
    (lib.mkIf (cfg.claudeCodeCli.enable && cfg.claudeCodeCli.createWheelUser) {
      users.users.claude = {
        isNormalUser = true;
        extraGroups = [ "wheel" ];
      };
    })
    (lib.mkIf cfg."oh-my-codex".enable (
      let
        codexOmxLayer = pkgs.dev.johnrinehart.codex-omx-layer;
      in
      {
        assertions = [
          {
            assertion = cfg.codexCli.enable;
            message = "dev.johnrinehart.agentTools.oh-my-codex.enable requires dev.johnrinehart.agentTools.codexCli.enable";
          }
        ];

        dev.johnrinehart.agentTools.codexCli.enable = lib.mkDefault true;

        environment.systemPackages = [
          pkgs.dev.johnrinehart.oh-my-codex
          pkgs.dev.johnrinehart.omx-agent-tools
        ];

        dev.johnrinehart.agentTools.codexCli.configLayers = lib.mkAfter [ codexOmxLayer.config ];
        dev.johnrinehart.agentTools.codexCli.hooksSource = lib.mkDefault codexOmxLayer.hooks;
      }
    ))
    (lib.mkIf (cfg.codexCli.enable && cfg.codexCli.hooksSource != null) {
      environment.etc."codex/hooks.json".source = cfg.codexCli.hooksSource;
    })
  ];
}
