# Lock the screen before the system sleeps, and wait until the lock holds.
#
# hypridle's before_sleep_cmd only starts hyprlock: it cannot wait for the
# lock on niri, which lacks hyprland-lock-notify-v1, so systemd froze
# hyprlock about 100 ms later, before it had locked (it takes about 2 s).
# The session then woke up unlocked until hyprlock caught up.
#
# This unit runs before sleep.target, so before systemd-sleep freezes the
# user slice. It asks logind to lock every session (hypridle starts
# hyprlock), then waits until the running hyprlock logs that the compositor
# confirmed the lock (ext-session-lock "locked"). After timeoutSeconds it
# lets the system sleep anyway, so a broken locker cannot keep it awake.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.desktop.lockBeforeSleep;
  niriCfg = config.dev.johnrinehart.desktop.greetd_niri;
  sleepTargets = [
    "suspend.target"
    "hibernate.target"
    "hybrid-sleep.target"
    "suspend-then-hibernate.target"
  ];
  lockAndWait = pkgs.writeShellScript "lock-before-sleep" ''
    set -u
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.procps
        config.systemd.package
      ]
    }

    # True if a running hyprlock has logged that its lock was confirmed.
    locked() {
      local pid
      for pid in $(pgrep -x hyprlock); do
        journalctl -q --no-pager -o cat _PID="$pid" | grep -q 'onLockLocked called' && return 0
      done
      return 1
    }

    if locked; then
      echo "already locked"
      exit 0
    fi

    loginctl lock-sessions

    deadline=$(( $(date +%s%N) + ${toString cfg.timeoutSeconds} * 1000000000 ))
    start=$(date +%s%N)
    while (( $(date +%s%N) < deadline )); do
      if locked; then
        echo "locked after $(( ($(date +%s%N) - start) / 1000000 )) ms"
        exit 0
      fi
      sleep 0.1
    done
    echo "hyprlock did not confirm the lock within ${toString cfg.timeoutSeconds} s; sleeping anyway" >&2
    exit 0
  '';
in
{
  options.dev.johnrinehart.desktop.lockBeforeSleep = {
    enable = lib.mkEnableOption "locking the screen, and waiting for the lock, before each sleep" // {
      default = niriCfg.enable && niriCfg.hypridle.enable;
      defaultText = lib.literalExpression "greetd_niri.enable && greetd_niri.hypridle.enable";
    };

    timeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Longest wait for the lock before the system sleeps anyway. hyprlock needs about 2 s.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.lock-before-sleep = {
      description = "Lock the screen and wait for the lock before sleep";
      before = sleepTargets;
      wantedBy = sleepTargets;
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lockAndWait;
        TimeoutStartSec = cfg.timeoutSeconds + 5;
      };
    };
  };
}
