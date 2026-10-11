{ inputs, lib, ... }:
{
  config._module.args.inputs = lib.mkDefault inputs;

  options.dev.johnrinehart.users = {
    primary = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z_][A-Za-z0-9_-]*";
      default = "john";
      example = "jrinehart";
      description = ''
        Primary login user for JohnOS system and Home Manager configuration.
      '';
    };

  };

  imports = [
    inputs.home-manager.nixosModules.default
    inputs.sops-nix.nixosModules.default
    (
      {
        config,
        lib,
        pkgs,
        ...
      }:
      {
        options.dev.johnrinehart.users.terminalEmulator = {
          package = lib.mkOption {
            type = lib.types.package;
            default = pkgs.kitty;
            description = "Terminal emulator package for the primary user.";
          };
          integrations.kitty.enable = lib.mkEnableOption "KiTTY-specific terminal integration";
        };

        config.dev.johnrinehart.users.terminalEmulator.integrations.kitty.enable = lib.mkDefault (
          (config.dev.johnrinehart.users.terminalEmulator.package.pname or "") == "kitty"
        );
        config.warnings = lib.optional (
          config.dev.johnrinehart.users.terminalEmulator.integrations.kitty.enable
          && (config.dev.johnrinehart.users.terminalEmulator.package.pname or "") != "kitty"
        ) "KiTTY integration is enabled, but the primary terminal emulator package pname is not \"kitty\".";
      }
    )

    (
      { config, pkgs, ... }:
      {
        config =
          lib.mkIf (config.dev.johnrinehart.s3_mount.enable || config.dev.johnrinehart.gocryptfs.enable)
            {
              # The s3fs and gocryptfs modules use filesystem types like
              # fuse./nix/store/.../bin/s3fs. This patched mount helper lookup is
              # required for store paths with multiple periods.
              systemd.package = pkgs.systemd.override {
                util-linux = pkgs.dev.johnrinehart.util-linux;
              };
            };
      }
    )

    ./agent-tools.nix
    ./auto-suspend.nix
    ./bluetooth.nix
    ./hibernate-resume-optimization.nix
    ./droidcam.nix
    ./daylight-display.nix
    ./display-brightness.nix
    ./external-display-recovery.nix
    ./external-display-telemetry.nix
    ./filepicker.nix
    ./firmware/framework-ec.nix
    ./fonts.nix
    ./git-meld.nix
    ./kitkat-rs.nix
    ./gocryptfs.nix
    ./ide.nix
    ./laptop.nix
    ./locale.nix
    ./network.nix
    ./monstar.nix
    ./nebula
    ./nix.nix
    ./obsidian.nix
    ./oh-my-posh.nix
    ./packages.nix
    ./repo-manager.nix
    ./s3_mount.nix
    ./sound.nix
    ./ssh.nix
    ./ssh-session-lock.nix
    ./system.nix
    ./thunderbolt-debug.nix
    ./tmux.nix
    ./tmux-socket.nix
    ./virtualisation.nix
    ./voice-dictation.nix
    ./profiles/laptop.nix

    ./desktop/default.nix
    ./desktop/hyprland.nix
    ./desktop/greetd+niri.nix
    ./desktop/xmonad.nix
    ./desktop/xorg-xmonad.nix
    ./desktop/xorg.nix

    ./bootloader
    ./kernel
  ];

}
