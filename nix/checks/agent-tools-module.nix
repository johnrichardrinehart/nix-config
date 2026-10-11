{
  inputs,
  lib,
  pkgs,
}:
let
  evaluate =
    agentTools:
    lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        (import ../../nixos-modules { inherit inputs lib; })
        {
          nixpkgs.hostPlatform = "x86_64-linux";
          nixpkgs.overlays = [ (import ../../overlays inputs).default ];
          system.stateVersion = "24.05";
          dev.johnrinehart.agentTools = agentTools;
        }
      ];
    };
  profile = (evaluate { enable = true; }).config;
  piOnly = (evaluate { pi.enable = true; }).config;
  ompOnly = (evaluate { omp.enable = true; }).config;
  primeAgentOnly = (evaluate { primeAgent.enable = true; }).config;
  codexOnly = (evaluate { codexCli.enable = true; }).config;
  claudeOnly = (evaluate { claudeCodeCli.enable = true; }).config;
  omxProfile = (evaluate { "oh-my-codex".enable = true; }).config;
  invalidOmxProfile =
    (evaluate {
      "oh-my-codex".enable = true;
      codexCli.enable = false;
    }).config;
  dedicatedUsers =
    (evaluate {
      pi = {
        enable = true;
        createWheelUser = true;
      };
      primeAgent = {
        enable = true;
        createWheelUser = true;
      };
      codexCli = {
        enable = true;
        createWheelUser = true;
      };
      claudeCodeCli = {
        enable = true;
        createWheelUser = true;
      };
    }).config;
  packageNames = config: map lib.getName config.environment.systemPackages;
  findOmpPackage =
    config:
    lib.findFirst (package: lib.getName package == "omp") null config.environment.systemPackages;
  failedAssertions = config: builtins.filter (entry: !entry.assertion) config.assertions;
  hasWheelUser =
    name: config:
    config.users.users.${name}.isNormalUser
    && builtins.elem "wheel" config.users.users.${name}.extraGroups;
in
assert builtins.all (name: builtins.elem name (packageNames profile)) [
  "pi"
  "omp"
  "prime-agent"
  "codex-cli-nix"
  "claude-code-nix"
];
assert profile.home-manager.users.john.home.activation ? ompConfig;
assert lib.hasInfix "runtime-config.yml"
  profile.home-manager.users.john.home.activation.ompConfig.data;
assert lib.hasInfix "keybindings.yml"
  profile.home-manager.users.john.home.activation.ompConfig.data;
assert lib.hasInfix "mcp.json" profile.home-manager.users.john.home.activation.ompConfig.data;
assert lib.hasInfix "context-mode" profile.home-manager.users.john.home.activation.ompConfig.data;
assert
  profile.home-manager.users.john.home.sessionVariables.PI_CONFIG_FILES
  == "/home/john/.omp/agent/runtime-config.yml";
assert
  profile.home-manager.users.john.programs.kitty.keybindings."ctrl+shift+backspace"
  == "send_text all \\x1b[127;6u";
assert lib.hasInfix (builtins.unsafeDiscardStringContext ''
  [omp]
  command = "${lib.getExe (findOmpPackage profile)}"
'') profile.home-manager.users.john.home.file.".agent-deck/config.toml".text;
assert !(profile.users.users ? pi);
assert !(builtins.hasAttr "prime-agent" profile.users.users);
assert !(profile.users.users ? codex);
assert !(profile.users.users ? claude);
assert builtins.elem "pi" (packageNames piOnly);
assert !(builtins.elem "prime-agent" (packageNames piOnly));
assert !(builtins.elem "codex-cli-nix" (packageNames piOnly));
assert !(builtins.elem "claude-code-nix" (packageNames piOnly));
assert builtins.elem "omp" (packageNames ompOnly);
assert builtins.elem "python3" (map lib.getName (findOmpPackage ompOnly).runtimeInputs);
assert builtins.elem "context-mode" (map lib.getName (findOmpPackage ompOnly).plugins);
assert
  map lib.getName (findOmpPackage ompOnly).pluginRuntimeInputs == [
    "bun"
    "cargo"
    "rustc"
  ];
assert builtins.elem "context-mode" ompOnly.dev.johnrinehart.nix.allowedUnfreePackages;
assert !(builtins.elem "pi" (packageNames ompOnly));
assert !(builtins.elem "prime-agent" (packageNames ompOnly));
assert !(builtins.elem "codex-cli-nix" (packageNames ompOnly));
assert !(builtins.elem "claude-code-nix" (packageNames ompOnly));
assert builtins.elem "prime-agent" (packageNames primeAgentOnly);
assert !(builtins.elem "pi" (packageNames primeAgentOnly));
assert !(builtins.elem "codex-cli-nix" (packageNames primeAgentOnly));
assert !(builtins.elem "claude-code-nix" (packageNames primeAgentOnly));
assert builtins.elem "codex-cli-nix" (packageNames codexOnly);
assert !(builtins.elem "pi" (packageNames codexOnly));
assert !(builtins.elem "prime-agent" (packageNames codexOnly));
assert !(builtins.elem "claude-code-nix" (packageNames codexOnly));
assert codexOnly.environment.etc ? "codex/config.toml";
assert builtins.elem "claude-code-nix" (packageNames claudeOnly);
assert !(builtins.elem "pi" (packageNames claudeOnly));
assert !(builtins.elem "prime-agent" (packageNames claudeOnly));
assert !(builtins.elem "codex-cli-nix" (packageNames claudeOnly));
assert builtins.elem "codex-cli-nix" (packageNames omxProfile);
assert builtins.elem "oh-my-codex" (packageNames omxProfile);
assert omxProfile.environment.etc ? "codex/config.toml";
assert omxProfile.environment.etc ? "codex/hooks.json";
assert builtins.any (
  entry:
  entry.message
  == "dev.johnrinehart.agentTools.oh-my-codex.enable requires dev.johnrinehart.agentTools.codexCli.enable"
) (failedAssertions invalidOmxProfile);
assert !(invalidOmxProfile.environment.etc ? "codex/config.toml");
assert !(invalidOmxProfile.environment.etc ? "codex/hooks.json");
assert hasWheelUser "pi" dedicatedUsers;
assert hasWheelUser "prime-agent" dedicatedUsers;
assert hasWheelUser "codex" dedicatedUsers;
assert hasWheelUser "claude" dedicatedUsers;
pkgs.runCommand "agent-tools-module-evaluation" { } ''
  touch $out
''
