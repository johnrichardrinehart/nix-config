{
  inputs,
  lib,
  pkgs,
}:
let
  mockUpower = pkgs.writeShellScriptBin "upower" ''
        set -euo pipefail

        case "$1" in
          -e)
            echo /org/freedesktop/UPower/devices/battery_BAT1
            ;;
          -i)
            count=0
            if [ -f "$TEST_UPOWER_COUNTER" ]; then
              count=$(${pkgs.coreutils}/bin/cat "$TEST_UPOWER_COUNTER")
            fi
            count=$((count + 1))
            echo "$count" > "$TEST_UPOWER_COUNTER"

            state=discharging
            if [ "$TEST_POWER_MODE" = "charging" ]; then
              state=charging
            elif [ "$TEST_POWER_MODE" = "transition" ] && [ "$count" -gt 1 ]; then
              state=charging
            fi

            percent="''${TEST_PERCENT:-29}"
            cat <<EOF
      state:               $state
      percentage:          $percent%
      energy:              $percent Wh
      energy-full:         100 Wh
      capacity-level:      Normal
    EOF
            ;;
          *)
            exit 1
            ;;
        esac
  '';
  mockSystemd = pkgs.writeShellScriptBin "systemctl" ''
    printf 'systemctl %s\n' "$*" >> "$TEST_LOG"
    if [ "$1" = "is-active" ]; then
      [ "''${TEST_UNIT_ACTIVE:-0}" = 1 ]
    fi
  '';
  testPkgs = pkgs // {
    upower = mockUpower;
    systemd = mockSystemd;
  };
  dismissNotificationsScript = pkgs.writeShellScript "dismiss-test-notifications" ''
    echo dismiss >> "$TEST_LOG"
  '';
  sendNotificationScript = pkgs.writeShellScript "send-test-notification" ''
    printf 'notify %s\n' "$*" >> "$TEST_LOG"
  '';
  checkBatteryScript = import ../../nixos-modules/auto-suspend-check-battery.nix {
    pkgs = testPkgs;
    lowLevel = 20;
    criticalLevel = 10;
    notificationLevels = [ 30 ];
    inherit dismissNotificationsScript sendNotificationScript;
  };
  checkBatteryWithPromptScript = import ../../nixos-modules/auto-suspend-check-battery.nix {
    pkgs = testPkgs;
    lowLevel = 20;
    criticalLevel = 10;
    notificationLevels = [ 30 ];
    sshPromptUnit = "auto-suspend-ssh-prompt.service";
    inherit dismissNotificationsScript sendNotificationScript;
  };
  handlePowerStateScript = import ../../nixos-modules/auto-suspend-handle-power-state.nix {
    pkgs = testPkgs;
    inherit dismissNotificationsScript;
  };
  evaluated = lib.nixosSystem {
    specialArgs = { inherit inputs; };
    modules = [
      (import ../../nixos-modules { inherit inputs lib; })
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        nixpkgs.overlays = [ (import ../../overlays inputs).default ];
        system.stateVersion = "24.05";
        dev.johnrinehart.auto-suspend.enable = true;
      }
    ];
  };
  monitorService = evaluated.config.systemd.services.auto-suspend-power-monitor;
in
assert builtins.elem "multi-user.target" monitorService.wantedBy;
assert monitorService.serviceConfig.Restart == "always";
pkgs.runCommand "auto-suspend-module" { } ''
  export AUTO_SUSPEND_STATE_DIR="$TMPDIR/state"
  export AUTO_SUSPEND_POWER_STATE_FILE="$TMPDIR/power-state"
  export TEST_LOG="$TMPDIR/actions"
  export TEST_UPOWER_COUNTER="$TMPDIR/upower-counter"

  # `! cmd` never fails under `set -e`; this does.
  refute() {
    if "$@"; then
      echo "unexpected success: $*" >&2
      exit 1
    fi
  }

  reset_test() {
    rm -rf "$AUTO_SUSPEND_STATE_DIR"
    mkdir -p "$AUTO_SUSPEND_STATE_DIR"
    rm -f "$AUTO_SUSPEND_POWER_STATE_FILE" "$TEST_UPOWER_COUNTER"
    : > "$TEST_LOG"
    unset TEST_PERCENT TEST_UNIT_ACTIVE
  }

  reset_test
  export TEST_POWER_MODE=charging
  ${checkBatteryScript}
  grep -Fx dismiss "$TEST_LOG"
  refute grep -q '^notify ' "$TEST_LOG"
  refute grep -q '^systemctl ' "$TEST_LOG"

  reset_test
  export TEST_POWER_MODE=transition
  ${checkBatteryScript}
  grep -Fx dismiss "$TEST_LOG"
  refute grep -q '^notify ' "$TEST_LOG"
  refute grep -q '^systemctl ' "$TEST_LOG"

  reset_test
  export TEST_POWER_MODE=discharging
  ${checkBatteryScript}
  grep -Fx 'notify Low Battery Battery at 29%. Please plug in charger. normal' "$TEST_LOG"
  refute grep -q '^dismiss$' "$TEST_LOG"
  refute grep -q '^systemctl ' "$TEST_LOG"

  reset_test
  touch "$AUTO_SUSPEND_STATE_DIR/last-action" "$AUTO_SUSPEND_STATE_DIR/notified-levels"
  export TEST_POWER_MODE=charging
  ${handlePowerStateScript}
  grep -Fx 'systemctl stop auto-suspend-check.service' "$TEST_LOG"
  grep -Fx dismiss "$TEST_LOG"
  test ! -e "$AUTO_SUSPEND_STATE_DIR/last-action"
  test ! -e "$AUTO_SUSPEND_STATE_DIR/notified-levels"

  : > "$TEST_LOG"
  ${handlePowerStateScript}
  test ! -s "$TEST_LOG"

  reset_test
  touch "$AUTO_SUSPEND_STATE_DIR/last-action" "$AUTO_SUSPEND_STATE_DIR/notified-levels"
  rm -f "$AUTO_SUSPEND_POWER_STATE_FILE.last-check"
  export TEST_POWER_MODE=discharging
  ${handlePowerStateScript}
  test -e "$AUTO_SUSPEND_STATE_DIR/last-action"
  test -e "$AUTO_SUSPEND_STATE_DIR/notified-levels"
  # Battery updates while discharging start a check...
  grep -Fx 'systemctl start --no-block auto-suspend-check.service' "$TEST_LOG"
  refute grep -q -e '^dismiss$' -e '^systemctl stop' "$TEST_LOG"

  # ...but no more often than eventCheckIntervalSeconds.
  : > "$TEST_LOG"
  ${handlePowerStateScript}
  test ! -s "$TEST_LOG"

  # Low level with SSH sessions: start the prompt unit and return at once.
  reset_test
  export TEST_POWER_MODE=discharging TEST_PERCENT=19
  ${checkBatteryWithPromptScript}
  grep -Fx 'systemctl start --no-block auto-suspend-ssh-prompt.service' "$TEST_LOG"
  refute grep -qx 'systemctl \(suspend\|suspend-then-hibernate\|hibernate\)' "$TEST_LOG"
  test ! -e "$AUTO_SUSPEND_STATE_DIR/last-action"

  # A running prompt is not restarted, and does not block the check.
  : > "$TEST_LOG"
  export TEST_UNIT_ACTIVE=1
  ${checkBatteryWithPromptScript}
  refute grep -q '^systemctl start' "$TEST_LOG"

  # Fresh activity defers the low action.
  reset_test
  export TEST_POWER_MODE=discharging TEST_PERCENT=19
  echo "active $(date +%s)" > "$AUTO_SUSPEND_STATE_DIR/ssh-prompt"
  ${checkBatteryWithPromptScript}
  refute grep -q '^systemctl start' "$TEST_LOG"
  refute grep -q 'suspend-then-hibernate' "$TEST_LOG"

  # An idle answer lets the low action proceed and is consumed.
  reset_test
  export TEST_POWER_MODE=discharging TEST_PERCENT=19
  echo "idle $(date +%s)" > "$AUTO_SUSPEND_STATE_DIR/ssh-prompt"
  ${checkBatteryWithPromptScript}
  grep -Fx 'systemctl suspend-then-hibernate' "$TEST_LOG"
  test ! -e "$AUTO_SUSPEND_STATE_DIR/ssh-prompt"

  # Critical stops a pending prompt and acts without waiting.
  reset_test
  export TEST_POWER_MODE=discharging TEST_PERCENT=9 TEST_UNIT_ACTIVE=1
  ${checkBatteryWithPromptScript}
  grep -Fx 'systemctl stop --no-block auto-suspend-ssh-prompt.service' "$TEST_LOG"
  grep -q '^systemctl suspend-then-hibernate\|^systemctl hibernate' "$TEST_LOG"

  # A second check skips while another holds the lock.
  reset_test
  export TEST_POWER_MODE=discharging
  exec 8>"$AUTO_SUSPEND_STATE_DIR/check.lock"
  ${pkgs.util-linux}/bin/flock -n 8
  ${checkBatteryScript} | grep -Fx 'Another battery check is running, skipping'
  exec 8>&-
  test ! -s "$TEST_LOG"

  touch "$out"
''
