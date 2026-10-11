{
  pkgs,
  dismissNotificationsScript,
  stateDir ? "/var/lib/auto-suspend",
  powerStateFile ? "/run/auto-suspend/power-state",
}:

pkgs.writeShellScript "handle-auto-suspend-power-state" ''
  set -euo pipefail

  state_dir="''${AUTO_SUSPEND_STATE_DIR:-${stateDir}}"
  state_file="''${AUTO_SUSPEND_POWER_STATE_FILE:-${powerStateFile}}"
  battery_path=$(${pkgs.upower}/bin/upower -e | ${pkgs.gnugrep}/bin/grep -i battery | ${pkgs.coreutils}/bin/head -n1)

  if [ -z "$battery_path" ]; then
    exit 0
  fi

  state=$(
    ${pkgs.upower}/bin/upower -i "$battery_path" |
      ${pkgs.gnugrep}/bin/grep -w state |
      ${pkgs.gawk}/bin/awk '{print $2}'
  )

  previous_state=""
  if [ -f "$state_file" ]; then
    previous_state=$(${pkgs.coreutils}/bin/cat "$state_file")
  fi

  if [ "$state" = "$previous_state" ]; then
    exit 0
  fi

  printf '%s\n' "$state" > "$state_file"

  if [ "$state" = "discharging" ]; then
    exit 0
  fi

  # Cancel a check that uses an older discharging snapshot.
  ${pkgs.systemd}/bin/systemctl stop auto-suspend-check.service
  ${dismissNotificationsScript}
  ${pkgs.coreutils}/bin/rm -f "$state_dir/last-action" "$state_dir/notified-levels"
  echo "Battery is $state; cancelled discharge actions and dismissed warnings"
''
