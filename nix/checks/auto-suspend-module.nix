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

            cat <<EOF
      state:               $state
      percentage:          29%
      energy:              29 Wh
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

  reset_test() {
    rm -rf "$AUTO_SUSPEND_STATE_DIR"
    mkdir -p "$AUTO_SUSPEND_STATE_DIR"
    rm -f "$AUTO_SUSPEND_POWER_STATE_FILE" "$TEST_UPOWER_COUNTER"
    : > "$TEST_LOG"
  }

  reset_test
  export TEST_POWER_MODE=charging
  ${checkBatteryScript}
  grep -Fx dismiss "$TEST_LOG"
  ! grep -q '^notify ' "$TEST_LOG"
  ! grep -q '^systemctl ' "$TEST_LOG"

  reset_test
  export TEST_POWER_MODE=transition
  ${checkBatteryScript}
  grep -Fx dismiss "$TEST_LOG"
  ! grep -q '^notify ' "$TEST_LOG"
  ! grep -q '^systemctl ' "$TEST_LOG"

  reset_test
  export TEST_POWER_MODE=discharging
  ${checkBatteryScript}
  grep -Fx 'notify Low Battery Battery at 29%. Please plug in charger. normal' "$TEST_LOG"
  ! grep -q '^dismiss$' "$TEST_LOG"
  ! grep -q '^systemctl ' "$TEST_LOG"

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
  export TEST_POWER_MODE=discharging
  ${handlePowerStateScript}
  test -e "$AUTO_SUSPEND_STATE_DIR/last-action"
  test -e "$AUTO_SUSPEND_STATE_DIR/notified-levels"
  test ! -s "$TEST_LOG"

  touch "$out"
''
