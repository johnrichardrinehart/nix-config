# Root shells in a root-owned tmux server, one server per root or wheel
# user, started without authentication once their graphical login succeeded.
#
# Graphical login starts the user unit tmux-root-shell.service, which starts
# the system unit tmux-root-shell@<user>.service; a polkit rule lets root
# and wheel members start and stop their own instance without a prompt.
# The instance runs a tmux server as root on
# /run/tmux-root-shell/<user>/socket, and lets only that user reach the
# socket (ACL) and the server (server-access). Each `root-shell` call
# creates its own session with its own root shell. The server stays up when
# the last shell exits (exit-empty off); ending the graphical session stops
# it, and the instance restarts it if it dies.
#
# This is passwordless root for every process the user runs during the
# graphical session: anything that can connect to the socket gets a root
# shell.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.tmux.rootShell;
  tmuxPackage = pkgs.dev.johnrinehart.tmux;
  tmux = lib.getExe tmuxPackage;
  socket = user: "/run/tmux-root-shell/${user}/socket";
  systemctl = lib.getExe' config.systemd.package "systemctl";

  attach = pkgs.writeShellApplication {
    name = "root-shell";
    text = ''
      exec ${tmux} -S "/run/tmux-root-shell/$(id -un)/socket" new-session -c /root "$@"
    '';
  };
in
{
  options.dev.johnrinehart.tmux.rootShell = {
    enable = lib.mkEnableOption ''
      a root-owned tmux server with a root shell for each root or wheel user,
      started without authentication at graphical login (passwordless root
      for every process of that user during the graphical session)
    '';
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ attach ];

    systemd.services."tmux-root-shell@" = {
      description = "Root-owned tmux server with a root shell for %i";
      path = [
        tmuxPackage
        pkgs.acl
      ];
      serviceConfig = {
        # start-server forks the server and returns. Without sessions the
        # server would exit at once; exit-empty off keeps it up.
        Type = "forking";
        RuntimeDirectory = "tmux-root-shell/%i";
        # Traversable, not listable; the socket's ACL admits only the user.
        RuntimeDirectoryMode = "0711";
        ExecStart = "${tmux} -S ${socket "%i"} start-server \\; set-option -g exit-empty off";
        ExecStartPost = [
          "${tmux} -S ${socket "%i"} server-access -a %i"
          # The mask doubles as the socket's group bits, which tmux keeps
          # when it updates the mode; the owning group's own entry stays ---.
          "${lib.getExe' pkgs.acl "setfacl"} -m u:%i:rw,m::rw ${socket "%i"}"
        ];
        # The server can be gone already, after a crash.
        ExecStop = "-${tmux} -S ${socket "%i"} kill-server";
        Restart = "always";
        RestartSec = 1;
      };
    };

    security.polkit.extraConfig = ''
      polkit.addRule(function (action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            action.lookup("unit") == "tmux-root-shell@" + subject.user + ".service" &&
            (action.lookup("verb") == "start" || action.lookup("verb") == "stop") &&
            (subject.user == "root" || subject.isInGroup("wheel"))) {
          return polkit.Result.YES;
        }
      });
    '';

    systemd.user.services.tmux-root-shell = {
      description = "Start the root-owned tmux server with a root shell";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      # Either condition suffices.
      unitConfig = {
        ConditionUser = "|root";
        ConditionGroup = "|wheel";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${systemctl} --no-ask-password start tmux-root-shell@%u.service";
        ExecStop = "${systemctl} --no-ask-password stop tmux-root-shell@%u.service";
      };
    };
  };
}
