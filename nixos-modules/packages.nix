{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.dev.johnrinehart.packages;

  # Log Chromium's Ozone/Wayland input routing. When Brave stops responding to
  # input, the log shows the drag, focus, cursor, and window state before the
  # freeze. Release builds have no logging for menus, capture, or IME.
  braveInputLogModules = [
    "wayland_event_source=1"
    "wayland_keyboard=1"
    "wayland_cursor=1"
    "wayland_toplevel_window=3"
    "wayland_window_drag_controller=1"
    "wayland_data_drag_controller=1"
    "wayland_data_device=1"
    "wayland_data_source=1"
    "tab_drag_controller=1"
  ];

  # Append the stderr of each launch, including child processes, to its own
  # file. The files survive restarts and reboots, and nothing deletes them.
  braveLogSetup = ''
    brave_log_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/brave-input-logs"
    ${pkgs.coreutils}/bin/mkdir -p "$brave_log_dir"
    exec 2>>"$brave_log_dir/brave-$(${pkgs.coreutils}/bin/date +%Y%m%dT%H%M%S)-$$.log"
    printf "%s launch: brave %s\n" "$(${pkgs.coreutils}/bin/date -Is)" "$*" >&2
  '';

  braveWithInputLogging =
    (pkgs.brave.override {
      commandLineArgs = lib.concatStringsSep " " [
        "--enable-logging=stderr"
        "--vmodule=${lib.concatStringsSep "," braveInputLogModules}"
      ];
    }).overrideAttrs
      (old: {
        preFixup = (old.preFixup or "") + ''
          gappsWrapperArgs+=(--run ${lib.escapeShellArg braveLogSetup})
        '';
      });
in
{
  options.dev.johnrinehart.packages = {
    shell.enable = lib.mkEnableOption "Shell tools (zoxide, tmux, fzf, ripgrep, fd, etc.)";
    editors.enable = lib.mkEnableOption "Text editors (vim)";
    gui.enable = lib.mkEnableOption "GUI apps (brave, vscodium, keepassxc, etc.)";
    devops.enable = lib.mkEnableOption "DevOps tools (minikube, kubectl)";
    media.enable = lib.mkEnableOption "Media tools (mpv, ffmpeg, obs-studio, etc.)";
    system.enable = lib.mkEnableOption "System utilities (htop, tree, lsof, etc.)";
    archive.enable = lib.mkEnableOption "Archive tools (zip, unzip)";
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.shell.enable {
      environment.systemPackages = [
        pkgs.zoxide
        pkgs.dev.johnrinehart.tmux
        pkgs.xdg-utils
        pkgs.fd
        pkgs.ripgrep
        pkgs.fzf
        pkgs.jq
        pkgs.bc
        pkgs.htop
        pkgs.tree
        pkgs.dev.johnrinehart.git-local-namespace
        pkgs.dev.johnrinehart.repo-manager
        pkgs.dev.johnrinehart.git-patch-wormhole
      ];
    })

    (lib.mkIf cfg.editors.enable {
      environment.systemPackages = [
        pkgs.vim
      ];
    })

    (lib.mkIf cfg.gui.enable {
      environment.systemPackages = [
        pkgs.dconf
        pkgs.libnotify
        pkgs.gnome-icon-theme
        pkgs.vscodium
        braveWithInputLogging
        pkgs.keepassxc
        pkgs.pavucontrol
        pkgs.gparted
      ];
    })

    (lib.mkIf cfg.devops.enable {
      environment.systemPackages = [
        pkgs.kubectl
      ];
    })

    (lib.mkIf cfg.media.enable {
      environment.systemPackages = [
        pkgs.mpv
        pkgs.simplescreenrecorder
        pkgs.obs-studio
        pkgs.playerctl
        pkgs.ffmpeg_7-full
        pkgs.deluge
      ];
    })

    (lib.mkIf cfg.system.enable {
      environment.systemPackages = [
        pkgs.pciutils
        pkgs.usbutils
        pkgs.wirelesstools
        pkgs.alsa-tools
        pkgs.alsa-utils
        pkgs.dig
        pkgs.tree
        pkgs.killall
        pkgs.lsof
        pkgs.pstree
        pkgs.nethogs
        pkgs.file
        pkgs.pv
        pkgs.ncdu
        pkgs.ntfs3g
        pkgs.libqalculate
        pkgs.tokei
        pkgs.libxml2
        pkgs.openconnect
      ];
    })

    (lib.mkIf cfg.archive.enable {
      environment.systemPackages = [
        pkgs.zip
        pkgs.unzip
      ];
    })
  ];
}
