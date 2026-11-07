{
  pkgs,
  dismissNotificationsScript,
  stateDir ? "/var/lib/auto-suspend",
  powerStateFile ? "/run/auto-suspend/power-state",
  sshPromptUnit ? "",
  # Minimum spacing between event-triggered battery checks.
  eventCheckIntervalSeconds ? 15,
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

  if [ "$state" != "$previous_state" ]; then
    printf '%s\n' "$state" > "$state_file"
  fi

  if [ "$state" = "discharging" ]; then
    # UPower refreshes the battery every 10-30 s. Check on those updates
    # rather than only on the timer: a busy laptop can lose 5% per minute.
    trigger_file="$state_file.last-check"
    now=$(${pkgs.coreutils}/bin/date +%s)
    last_check=0
    if [ -f "$trigger_file" ]; then
      last_check=$(${pkgs.coreutils}/bin/cat "$trigger_file")
    fi
    case "$last_check" in
      "" | *[!0-9]*) last_check=0 ;;
    esac
    if [ $((now - last_check)) -ge ${toString eventCheckIntervalSeconds} ]; then
      printf '%s\n' "$now" > "$trigger_file"
      ${pkgs.systemd}/bin/systemctl start --no-block auto-suspend-check.service
    fi
    exit 0
  fi

  if [ "$state" = "$previous_state" ]; then
    exit 0
  fi

  # Cancel a check that uses an older discharging snapshot.
  ${pkgs.systemd}/bin/systemctl stop auto-suspend-check.service
  ssh_prompt_unit=${pkgs.lib.escapeShellArg sshPromptUnit}
  if [ -n "$ssh_prompt_unit" ]; then
    ${pkgs.systemd}/bin/systemctl stop "$ssh_prompt_unit" || true
  fi
  ${dismissNotificationsScript}
  ${pkgs.coreutils}/bin/rm -f "$state_dir/last-action" "$state_dir/notified-levels" "$state_dir/ssh-prompt"
  echo "Battery is $state; cancelled discharge actions and dismissed warnings"
''
