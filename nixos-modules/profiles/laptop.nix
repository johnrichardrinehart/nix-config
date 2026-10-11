{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.profiles.laptop;
  primaryUser = config.dev.johnrinehart.users.primary;
in
{
  options.dev.johnrinehart.profiles.laptop.enable =
    lib.mkEnableOption "the opinionated laptop work environment";

  config = lib.mkIf cfg.enable {
    documentation.nixos.enable = lib.mkDefault false;
    programs.ssh.extraConfig = lib.mkDefault ''
      Host *
        ConnectTimeout 2
    '';
    virtualisation.containers.enable = lib.mkDefault true;

    users.users.${primaryUser}.extraGroups = lib.mkDefault [ "input" ];
    systemd.services."user@".serviceConfig.Delegate = lib.mkDefault "cpu cpuset io memory pids";

    dev.johnrinehart = {
      laptop.enable = lib.mkDefault true;
      system.enable = lib.mkDefault true;
      repo-manager.daemon.enable = lib.mkDefault true;

      agentTools = {
        enable = lib.mkDefault true;
        "oh-my-codex".enable = lib.mkDefault false;
        codexCli.statusLinePlugins = lib.mkDefault [ "codex-weekly-pace" ];
      };

      desktop = {
        enable = lib.mkDefault true;
        displayBrightness.enable = lib.mkDefault true;
        variant = lib.mkDefault "greetd+niri";
        greetd_niri.waybar.systemd.enable = lib.mkDefault true;
        obsidian.enable = lib.mkDefault true;
      };

      sshSessionLock = {
        enable = lib.mkDefault true;
        timeoutSeconds = lib.mkDefault (60 * 15);
        suspendPromptTimeoutSeconds = lib.mkDefault (60 * 15);
        terminalMultiplexer = lib.mkDefault "tmux";
        forceInteractiveShellsIntoMultiplexer = lib.mkDefault true;
        multiplexerSessionName = lib.mkDefault "ssh";
      };

      packages = {
        shell.enable = lib.mkDefault true;
        editors.enable = lib.mkDefault true;
        gui.enable = lib.mkDefault true;
        devops.enable = lib.mkDefault true;
        media.enable = lib.mkDefault true;
        system.enable = lib.mkDefault true;
        archive.enable = lib.mkDefault true;
      };

      bluetooth = {
        enable = lib.mkDefault true;
        autoSuspend.enable = lib.mkDefault true;
      };

      terminal.filepicker.enable = lib.mkDefault true;
      users.terminalEmulator.package = lib.mkDefault pkgs.dev.johnrinehart.monstar;
    };
  };
}
