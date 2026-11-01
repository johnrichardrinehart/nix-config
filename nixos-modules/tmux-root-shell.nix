# A standing tmux session with a root shell, for root and members of wheel.
#
# A graphical login starts tmux-root-shell.service in the user's manager,
# which creates the session in their canonical tmux server
# (dev.johnrinehart.tmux.socketDir/socketName) unless it exists. Its pane
# runs `command`, which asks for authentication as usual; once given, the
# pane stays a root shell. When that shell exits the pane waits for Enter
# and asks again, so the session does not disappear.
#
# Anything that can write to the user's tmux socket can type into an
# authenticated pane: the session trades re-authentication per command for
# convenience, as a root shell left open in a terminal does.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.tmux.rootShell;
  socketCfg = config.dev.johnrinehart.tmux;
  tmux = lib.getExe pkgs.dev.johnrinehart.tmux;

  paneScript = pkgs.writeShellScript "tmux-root-shell-pane" ''
    while :; do
      ${cfg.command}
      printf '\nRoot shell ended. Press Enter for a new one.\n'
      read -r _
    done
  '';
in
{
  options.dev.johnrinehart.tmux.rootShell = {
    enable = lib.mkEnableOption "a standing tmux session with a root shell for root and wheel members, created at graphical login";

    sessionName = lib.mkOption {
      type = lib.types.str;
      default = "root-shell";
      description = "Name of the tmux session.";
    };

    command = lib.mkOption {
      type = lib.types.str;
      default =
        if config.security.sudo.enable then
          "${config.security.wrapperDir}/sudo -i"
        else
          lib.getExe' config.systemd.package "run0";
      defaultText = lib.literalExpression ''"''${config.security.wrapperDir}/sudo -i" (run0 without sudo)'';
      description = ''
        Command the session's pane runs to become root. For root itself the
        pane runs root's login shell instead.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.tmux-root-shell = {
      description = "tmux session with a root shell";
      wantedBy = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      # Either condition suffices.
      unitConfig = {
        ConditionUser = "|root";
        ConditionGroup = "|wheel";
      };
      environment.TMUX_TMPDIR = socketCfg.socketDir;
      path = [
        pkgs.coreutils
        pkgs.getent
        config.systemd.package
      ];
      serviceConfig.Type = "oneshot";
      # The tmux server may start here. It gets a scope of its own, so it
      # outlives this oneshot unit as it would a terminal it was started from.
      script = ''
        tmux() { ${tmux} -L ${lib.escapeShellArg socketCfg.socketName} "$@"; }
        if tmux has-session -t ${lib.escapeShellArg "=${cfg.sessionName}"} 2>/dev/null; then
          exit 0
        fi
        if [ "$(id -u)" = 0 ]; then
          cmd="$(getent passwd root | cut -d: -f7) -l"
        else
          cmd=${paneScript}
        fi
        systemd-run --user --scope --quiet --collect \
          ${tmux} -L ${lib.escapeShellArg socketCfg.socketName} \
          new-session -d -s ${lib.escapeShellArg cfg.sessionName} -c "$HOME" "$cmd"
      '';
    };
  };
}
