{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.auto-suspend;
  sshSessionLockCfg = config.dev.johnrinehart.sshSessionLock;
  notificationUser = config.dev.johnrinehart.users.primary;

  notificationIdsFile = "/var/lib/auto-suspend/notification-ids";
  powerStateFile = "/run/auto-suspend/power-state";
  sendNotificationScript = pkgs.writeShellScript "send-auto-suspend-notification" ''
    set -euo pipefail

    title="$1"
    message="$2"
    urgency="$3"
    username=${lib.escapeShellArg notificationUser}
    uid=$(${pkgs.coreutils}/bin/id -u "$username")

    if [ ! -S "/run/user/$uid/bus" ]; then
      exit 0
    fi

    if notification_id=$(
      ${pkgs.util-linux}/bin/runuser --user "$username" -- \
        ${pkgs.coreutils}/bin/env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        ${pkgs.libnotify}/bin/notify-send \
        --print-id \
        --urgency="$urgency" \
        --app-name="Auto-Suspend" \
        "$title" \
        "$message"
    ); then
      case "$notification_id" in
        "" | *[!0-9]*) exit 0 ;;
      esac
      {
        ${pkgs.util-linux}/bin/flock 9 || exit 1
        printf '%s %s\n' "$uid" "$notification_id" >> ${lib.escapeShellArg notificationIdsFile}
      } 9>${lib.escapeShellArg "${notificationIdsFile}.lock"}
    fi
  '';
  dismissNotificationsScript = pkgs.writeShellScript "dismiss-auto-suspend-notifications" ''
    set -u

    ids_file=${lib.escapeShellArg notificationIdsFile}
    pending_file="$ids_file.pending"

    {
      ${pkgs.util-linux}/bin/flock 9 || exit 1
      [ -s "$ids_file" ] || exit 0
      : > "$pending_file"

      while read -r uid notification_id; do
        case "$uid" in
          "" | *[!0-9]*) continue ;;
        esac
        case "$notification_id" in
          "" | *[!0-9]*) continue ;;
        esac

        username=$(${pkgs.coreutils}/bin/id -un "$uid" 2>/dev/null || true)
        if [ -z "$username" ] || [ ! -S "/run/user/$uid/bus" ]; then
          printf '%s %s\n' "$uid" "$notification_id" >> "$pending_file"
          continue
        fi

        if ! ${pkgs.util-linux}/bin/runuser --user "$username" -- \
          ${pkgs.coreutils}/bin/env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
          ${pkgs.systemd}/bin/busctl --user call org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications CloseNotification u "$notification_id" \
          >/dev/null 2>&1; then
          printf '%s %s\n' "$uid" "$notification_id" >> "$pending_file"
        fi
      done < "$ids_file"

      if [ -s "$pending_file" ]; then
        ${pkgs.coreutils}/bin/mv "$pending_file" "$ids_file"
      else
        ${pkgs.coreutils}/bin/rm -f "$ids_file" "$pending_file"
      fi
    } 9>"$ids_file.lock"
  '';
  sshPromptEnabled = sshSessionLockCfg.enable;
  sshPromptUnit = lib.optionalString sshPromptEnabled "auto-suspend-ssh-prompt.service";

  # Runs outside auto-suspend-check.service, so checks keep running (and the
  # critical action stays possible) while SSH sessions have time to answer.
  sshPromptScript = pkgs.writeShellScript "auto-suspend-ssh-prompt" ''
    set -u

    confirm=${
      lib.getExe (
        pkgs.dev.johnrinehart.confirm-ssh-activity-before-suspend.override {
          promptTimeoutSeconds = cfg.sshPromptTimeoutSeconds;
        }
      )
    }
    status=0
    "$confirm" || status=$?

    # Exit 1 means activity; any other failure must not block suspend.
    result=idle
    if [ "$status" -eq 1 ]; then
      result=active
    elif [ "$status" -ne 0 ]; then
      echo "SSH prompt failed with status $status; treating sessions as idle"
    fi

    printf '%s %s\n' "$result" "$(${pkgs.coreutils}/bin/date +%s)" > /var/lib/auto-suspend/ssh-prompt
    ${pkgs.systemd}/bin/systemctl start --no-block auto-suspend-check.service
  '';

  handlePowerStateScript = import ./auto-suspend-handle-power-state.nix {
    inherit
      pkgs
      dismissNotificationsScript
      powerStateFile
      sshPromptUnit
      ;
    inherit (cfg) eventCheckIntervalSeconds;
  };

  powerMonitorScript = pkgs.writeShellScript "monitor-auto-suspend-power-state" ''
    set -euo pipefail

    ${pkgs.coreutils}/bin/rm -f ${lib.escapeShellArg powerStateFile}
    ${handlePowerStateScript}
    ${pkgs.upower}/bin/upower --monitor |
      while IFS= read -r event; do
        case "$event" in
          *"device changed:"*) ${handlePowerStateScript} ;;
        esac
      done
  '';

  # Script to check battery and suspend if needed
  checkBatteryScript = import ./auto-suspend-check-battery.nix {
    inherit pkgs;
    inherit (cfg) lowLevel criticalLevel notificationLevels;
    inherit dismissNotificationsScript sendNotificationScript sshPromptUnit;
    inherit (cfg) sshActivityDeferSeconds predictive criticalRepeatSeconds;
  };

  # Checks compare these stamps with their start time, so a check frozen by
  # sleep never acts on its pre-sleep battery snapshot.
  markSleepScript = pkgs.writeShellScript "auto-suspend-mark-sleep" ''
    ${pkgs.coreutils}/bin/mkdir -p /run/auto-suspend
    ${pkgs.coreutils}/bin/date +%s > /run/auto-suspend/last-sleep
  '';
  markResumeScript = pkgs.writeShellScript "auto-suspend-mark-resume" ''
    ${pkgs.coreutils}/bin/mkdir -p /run/auto-suspend
    ${pkgs.coreutils}/bin/date +%s > /run/auto-suspend/last-resume
    # A drain rate across sleep means nothing.
    ${pkgs.coreutils}/bin/rm -f /run/auto-suspend/discharge-samples
    ${dismissNotificationsScript}
  '';
in
{
  options.dev.johnrinehart.auto-suspend = {
    enable = lib.mkEnableOption "automatic battery-based suspend";

    lowLevel = lib.mkOption {
      type = lib.types.int;
      default = 15;
      description = ''
        Battery percentage at which to suspend (default: 15%).
        Internally converted to energy (Wh) based on battery capacity for more reliable detection.
        Also triggers when UPower reports 'low' capacity-level.
      '';
    };

    criticalLevel = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = ''
        Battery percentage at which to suspend-then-hibernate (default: 10%).
        Internally converted to energy (Wh) based on battery capacity for more reliable detection.
        Also triggers when UPower reports 'critical' capacity-level.
      '';
    };

    checkInterval = lib.mkOption {
      type = lib.types.str;
      default = "90s";
      description = ''
        Backup interval for battery checks (systemd timer format). While
        discharging, UPower battery updates also start a check, at most every
        `eventCheckIntervalSeconds`.
      '';
    };

    predictive = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Also act on the discharge rate. Each check records the charge; the
          drop over `windowSeconds` projects the minutes left until
          `emptyPercent`. Under heavy load a laptop can lose 5% per minute,
          so fixed levels alone can fire too late.
        '';
      };

      emptyPercent = lib.mkOption {
        type = lib.types.ints.between 0 100;
        default = 5;
        description = ''
          Gauge reading at which the battery cuts out under load. Worn
          batteries sag under high draw and can shut down well above 0%.
        '';
      };

      lowMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 6;
        description = "Projected minutes left that trigger the low action (suspend-then-hibernate).";
      };

      criticalMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = "Projected minutes left that trigger the critical action, without the SSH prompt.";
      };

      windowSeconds = lib.mkOption {
        type = lib.types.ints.between 60 600;
        default = 120;
        description = ''
          Span of samples used for the drain rate. Estimates need at least
          45 s of samples; gaps over 5 min (sleep) restart the window.
        '';
      };
    };

    criticalRepeatSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 180;
      description = ''
        After the critical action, how long a resumed system may run at
        critical charge before it hibernates again. Gives time to plug in.
      '';
    };

    eventCheckIntervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 15;
      description = ''
        Minimum spacing between battery checks started by UPower events.
      '';
    };

    sshPromptTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = ''
        How long SSH sessions may answer before a low-battery suspend, when
        `dev.johnrinehart.sshSessionLock` is enabled. The prompt runs in its
        own unit: checks continue meanwhile, and the critical action never
        waits for it. Kept short because a busy laptop can lose several
        percent per minute.
      '';
    };

    sshActivityDeferSeconds = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 600;
      description = ''
        How long SSH activity found by the prompt defers the low-battery
        suspend. The critical action ignores it.
      '';
    };

    notificationLevels = lib.mkOption {
      type = lib.types.listOf lib.types.int;
      default = [
        20
        15
        10
        5
      ];
      description = ''
        Battery percentage levels that send notifications (default: [20 15 10 5]).
        The module sends one notification for each level during a discharge cycle.
        Warnings require a current discharging state.
        It resets notified levels and dismisses warnings when charging starts.
        It also dismisses active battery warnings after the system resumes.
      '';
      example = [
        30
        20
        15
        10
        5
        3
        1
      ];
    };

  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.lowLevel > cfg.criticalLevel && cfg.criticalLevel > 1;
        message = "dev.johnrinehart.auto-suspend: lowLevel must exceed criticalLevel, and criticalLevel must exceed 1.";
      }
    ];

    # UPower's own policy is the backstop if these checks fail to act. Its
    # defaults (warn at 20/5%, hybrid-sleep at 2%) act too late for worn
    # batteries that cut out early under load. Keep low > critical > action,
    # as UPower expects.
    services.upower = {
      enable = true;
      percentageLow = lib.mkDefault cfg.lowLevel;
      percentageCritical = lib.mkDefault cfg.criticalLevel;
      percentageAction = lib.mkDefault (lib.max 1 (cfg.criticalLevel - 5));
      # Hibernate powers off after writing the image; HybridSleep would keep
      # draining the battery in suspend. Hosts that cannot hibernate get
      # UPower's PowerOff fallback either way.
      criticalPowerAction = lib.mkDefault "Hibernate";
    };

    # Create state directory
    systemd.tmpfiles.rules = [
      "d /var/lib/auto-suspend 0755 root root -"
    ];

    # Systemd service to check battery
    systemd.services.auto-suspend-check = {
      description = "Check battery level and auto-suspend if needed";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${checkBatteryScript}";
        # Run as root to access systemctl suspend
        User = "root";
      };
    };

    systemd.services.auto-suspend-ssh-prompt = lib.mkIf sshPromptEnabled {
      description = "Ask SSH sessions before a low-battery suspend";
      serviceConfig = {
        # Simple, so `systemctl is-active` reports a running prompt.
        Type = "simple";
        ExecStart = "${sshPromptScript}";
      };
    };

    # React to charging before the periodic check can use stale battery data.
    systemd.services.auto-suspend-power-monitor = {
      description = "Check the battery on UPower events and dismiss warnings when charging starts";
      wantedBy = [ "multi-user.target" ];
      after = [ "upower.service" ];
      wants = [ "upower.service" ];
      serviceConfig = {
        Type = "simple";
        RuntimeDirectory = "auto-suspend";
        # Discharge samples and sleep stamps outlive monitor restarts.
        RuntimeDirectoryPreserve = "yes";
        ExecStart = "${powerMonitorScript}";
        Restart = "always";
        RestartSec = "5s";
      };
    };

    # Record sleep and resume for the checks. Keep the warning visible during
    # sleep entry, then dismiss it after resume.
    systemd.services.auto-suspend-notification = {
      description = "Mark sleep and resume for auto-suspend; dismiss battery warnings after resume";
      wantedBy = [ "sleep.target" ];
      partOf = [ "sleep.target" ];
      before = [ "sleep.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${markSleepScript}";
        ExecStop = "${markResumeScript}";
        RemainAfterExit = true;
      };
    };

    # Timer to run the check periodically
    systemd.timers.auto-suspend-check = {
      description = "Timer for battery auto-suspend check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = cfg.checkInterval;
        Unit = "auto-suspend-check.service";
      };
    };
  };
}
