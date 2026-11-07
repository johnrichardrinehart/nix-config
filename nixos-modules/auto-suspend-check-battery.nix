{
  pkgs,
  lowLevel,
  criticalLevel,
  notificationLevels,
  # Empty disables the SSH prompt. Otherwise this unit asks SSH sessions
  # before a low-level suspend and writes "idle|active <epoch>" to
  # $STATE_DIR/ssh-prompt.
  sshPromptUnit ? "",
  sshActivityDeferSeconds ? 600,
  sshPromptResultMaxAgeSeconds ? 300,
  dismissNotificationsScript,
  sendNotificationScript,
  stateDir ? "/var/lib/auto-suspend",
}:

pkgs.writeShellScript "check-battery" ''
  set -euo pipefail

  STATE_DIR="''${AUTO_SUSPEND_STATE_DIR:-${stateDir}}"
  STATE_FILE="$STATE_DIR/last-action"
  NOTIFIED_FILE="$STATE_DIR/notified-levels"
  SSH_PROMPT_FILE="$STATE_DIR/ssh-prompt"
  SSH_PROMPT_UNIT=${pkgs.lib.escapeShellArg sshPromptUnit}
  ${pkgs.coreutils}/bin/mkdir -p "$STATE_DIR"

  # Timer runs and power events can overlap; only one check decides at a time.
  exec 9>"$STATE_DIR/check.lock"
  if ! ${pkgs.util-linux}/bin/flock -n 9; then
    echo "Another battery check is running, skipping"
    exit 0
  fi

  # Function to suspend with fallback
  do_suspend() {
    if ${pkgs.systemd}/bin/systemctl suspend-then-hibernate; then
      echo "Successfully initiated suspend-then-hibernate"
    else
      echo "suspend-then-hibernate failed, falling back to suspend"
      ${pkgs.systemd}/bin/systemctl suspend
    fi
  }

  # Get battery percentage using upower
  BATTERY_PATH=$(${pkgs.upower}/bin/upower -e | ${pkgs.gnugrep}/bin/grep -i battery | ${pkgs.coreutils}/bin/head -n1)

  if [ -z "$BATTERY_PATH" ]; then
    echo "No battery found, skipping auto-suspend check"
    exit 0
  fi

  # Get battery info
  BATTERY_INFO=$(${pkgs.upower}/bin/upower -i "$BATTERY_PATH")
  PERCENTAGE=$(echo "$BATTERY_INFO" | ${pkgs.gnugrep}/bin/grep -w percentage | ${pkgs.gawk}/bin/awk '{print $2}' | ${pkgs.coreutils}/bin/tr -d '%')
  STATE=$(echo "$BATTERY_INFO" | ${pkgs.gnugrep}/bin/grep -w state | ${pkgs.gawk}/bin/awk '{print $2}')
  CAPACITY_LEVEL=$(echo "$BATTERY_INFO" | ${pkgs.gnugrep}/bin/grep "capacity-level" | ${pkgs.gawk}/bin/awk '{print $2}')
  ENERGY=$(echo "$BATTERY_INFO" | ${pkgs.gnugrep}/bin/grep "^\s*energy:" | ${pkgs.gawk}/bin/awk '{print $2}')
  ENERGY_FULL=$(echo "$BATTERY_INFO" | ${pkgs.gnugrep}/bin/grep "energy-full:" | ${pkgs.gawk}/bin/awk '{print $2}')

  # Calculate energy thresholds from percentages
  LOW_ENERGY_THRESHOLD=$(echo "$ENERGY_FULL * ${toString lowLevel} / 100" | ${pkgs.bc}/bin/bc -l)
  CRITICAL_ENERGY_THRESHOLD=$(echo "$ENERGY_FULL * ${toString criticalLevel} / 100" | ${pkgs.bc}/bin/bc -l)

  stop_ssh_prompt() {
    if [ -n "$SSH_PROMPT_UNIT" ]; then
      ${pkgs.systemd}/bin/systemctl stop --no-block "$SSH_PROMPT_UNIT" || true
    fi
  }

  reset_discharge_cycle() {
    stop_ssh_prompt
    ${dismissNotificationsScript}
    ${pkgs.coreutils}/bin/rm -f "$STATE_FILE" "$NOTIFIED_FILE" "$SSH_PROMPT_FILE"
  }

  # Low-level suspends ask idle SSH sessions first. The prompt runs in its own
  # unit, so a pending prompt never blocks later checks or the critical action.
  # Returns 0 when the suspend may proceed now.
  ssh_prompt_allows_suspend() {
    local now result result_time
    if [ -z "$SSH_PROMPT_UNIT" ]; then
      return 0
    fi

    now=$(${pkgs.coreutils}/bin/date +%s)
    result=""
    result_time=""
    if [ -f "$SSH_PROMPT_FILE" ]; then
      read -r result result_time < "$SSH_PROMPT_FILE" || true
    fi
    case "$result_time" in
      "" | *[!0-9]*) result="" ;;
    esac

    if [ "$result" = "active" ] && [ $((now - result_time)) -lt ${toString sshActivityDeferSeconds} ]; then
      echo "SSH activity detected $((now - result_time))s ago, deferring low-battery suspend"
      return 1
    fi
    if [ "$result" = "idle" ] && [ $((now - result_time)) -lt ${toString sshPromptResultMaxAgeSeconds} ]; then
      ${pkgs.coreutils}/bin/rm -f "$SSH_PROMPT_FILE"
      return 0
    fi

    if ${pkgs.systemd}/bin/systemctl is-active --quiet "$SSH_PROMPT_UNIT"; then
      echo "Waiting for SSH sessions to answer the suspend prompt"
      return 1
    fi

    ${pkgs.coreutils}/bin/rm -f "$SSH_PROMPT_FILE"
    echo "Asking SSH sessions before low-battery suspend"
    ${pkgs.systemd}/bin/systemctl start --no-block "$SSH_PROMPT_UNIT"
    return 1
  }

  current_state() {
    ${pkgs.upower}/bin/upower -i "$BATTERY_PATH" |
      ${pkgs.gnugrep}/bin/grep -w state |
      ${pkgs.gawk}/bin/awk '{print $2}'
  }

  exit_unless_discharging() {
    local latest_state
    latest_state=$(current_state)
    if [ "$latest_state" != "discharging" ]; then
      echo "Battery is $latest_state, cancelling discharge actions"
      reset_discharge_cycle
      exit 0
    fi
  }

  # Warnings and suspend actions are valid only while power is discharging.
  if [ "$STATE" != "discharging" ]; then
    echo "Battery is $STATE ($PERCENTAGE%, $ENERGY Wh), not suspending"
    reset_discharge_cycle
    exit 0
  fi

  # Read last action from state file
  LAST_ACTION=""
  if [ -f "$STATE_FILE" ]; then
    LAST_ACTION=$(${pkgs.coreutils}/bin/cat "$STATE_FILE")
  fi

  echo "Battery at $PERCENTAGE% ($ENERGY Wh of $ENERGY_FULL Wh), capacity-level: $CAPACITY_LEVEL, state: $STATE, last action: $LAST_ACTION"
  echo "Thresholds: low=${toString lowLevel}% ($LOW_ENERGY_THRESHOLD Wh), critical=${toString criticalLevel}% ($CRITICAL_ENERGY_THRESHOLD Wh)"

  # Check notification levels and send ONE notification per check
  # Sort levels in ascending order to find the lowest (most urgent) uncrossed threshold
  NOTIFICATION_LEVELS="${
    pkgs.lib.concatStringsSep " " (map toString (pkgs.lib.sort (a: b: a < b) notificationLevels))
  }"
  NOTIFIED_LEVELS=""
  if [ -f "$NOTIFIED_FILE" ]; then
    NOTIFIED_LEVELS=$(${pkgs.coreutils}/bin/cat "$NOTIFIED_FILE")
  fi

  # Find the lowest (most urgent) threshold that was crossed but not yet notified
  NOTIFY_LEVEL=""
  for level in $NOTIFICATION_LEVELS; do
    if [ "$PERCENTAGE" -le "$level" ]; then
      if ! echo "$NOTIFIED_LEVELS" | ${pkgs.gnugrep}/bin/grep -q "\\<$level\\>"; then
        NOTIFY_LEVEL="$level"
        # Keep looking for lower levels (more urgent)
      fi
    fi
  done

  # Send notification for the lowest (most urgent) uncrossed threshold only
  if [ -n "$NOTIFY_LEVEL" ]; then
    # UPower can change state after the initial snapshot.
    exit_unless_discharging

    echo "Battery crossed $NOTIFY_LEVEL% threshold, sending notification"

    # Determine urgency and message based on current battery percentage and what action will be taken
    # Take into account LAST_ACTION to reflect whether system already suspended
    if [ "$PERCENTAGE" -le ${toString criticalLevel} ]; then
      urgency="critical"
      if [ "$LAST_ACTION" = "critical" ]; then
        message="Battery critically low at $PERCENTAGE%! System will power off soon."
      else
        message="Battery critically low at $PERCENTAGE%! System will suspend-then-hibernate immediately."
      fi
    elif [ "$PERCENTAGE" -le ${toString lowLevel} ]; then
      urgency="low"
      if [ "$LAST_ACTION" = "low" ]; then
        message="Battery at $PERCENTAGE%. Critical level will be reached soon."
      else
        message="Battery at $PERCENTAGE%. System will suspend soon."
      fi
    else
      urgency="normal"
      message="Battery at $PERCENTAGE%. Please plug in charger."
    fi

    ${sendNotificationScript} "Low Battery" "$message" "$urgency"

    # Mark ALL crossed levels as notified to avoid duplicate notifications
    for level in $NOTIFICATION_LEVELS; do
      if [ "$PERCENTAGE" -le "$level" ]; then
        if ! echo "$NOTIFIED_LEVELS" | ${pkgs.gnugrep}/bin/grep -q "\\<$level\\>"; then
          echo "$level" >> "$NOTIFIED_FILE"
        fi
      fi
    done
  fi

  # Critical level: UPower says "critical" OR energy below calculated threshold
  if [ "$CAPACITY_LEVEL" = "critical" ] || ([ -n "$ENERGY" ] && [ "$(echo "$ENERGY < $CRITICAL_ENERGY_THRESHOLD" | ${pkgs.bc}/bin/bc)" = "1" ]); then
    if [ "$LAST_ACTION" != "critical" ]; then
      # Critical never waits for SSH sessions.
      stop_ssh_prompt
      exit_unless_discharging
      echo "Battery critical (capacity-level=$CAPACITY_LEVEL or $ENERGY Wh < $CRITICAL_ENERGY_THRESHOLD Wh [${toString criticalLevel}%]), attempting suspend-then-hibernate"
      echo "critical" > "$STATE_FILE"
      do_suspend
    else
      echo "Already suspended at critical level, skipping"
    fi
    exit 0
  fi

  # Low level: UPower says "low" OR energy below calculated threshold
  if [ "$CAPACITY_LEVEL" = "low" ] || ([ -n "$ENERGY" ] && [ "$(echo "$ENERGY < $LOW_ENERGY_THRESHOLD" | ${pkgs.bc}/bin/bc)" = "1" ]); then
    if [ "$LAST_ACTION" != "low" ] && [ "$LAST_ACTION" != "critical" ]; then
      if ! ssh_prompt_allows_suspend; then
        exit 0
      fi
      exit_unless_discharging
      echo "Battery low (capacity-level=$CAPACITY_LEVEL or $ENERGY Wh < $LOW_ENERGY_THRESHOLD Wh [${toString lowLevel}%]), attempting suspend-then-hibernate"
      echo "low" > "$STATE_FILE"
      do_suspend
    else
      echo "Already suspended at low level, skipping"
    fi
    exit 0
  fi

  # Battery is above thresholds, clear state
  if [ "$CAPACITY_LEVEL" != "low" ] && [ "$CAPACITY_LEVEL" != "critical" ] && [ -n "$LAST_ACTION" ]; then
    echo "Battery recovered (capacity-level=$CAPACITY_LEVEL), clearing state"
    ${pkgs.coreutils}/bin/rm -f "$STATE_FILE"
    ${dismissNotificationsScript}
  fi

  # Keep notified levels until charging starts.
  # This limits each level to one warning per discharge cycle.
''
