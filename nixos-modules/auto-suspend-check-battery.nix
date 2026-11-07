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
  # After a critical action, how long a resumed system may run at critical
  # charge before the critical action repeats.
  criticalRepeatSeconds ? 180,
  dismissNotificationsScript,
  sendNotificationScript,
  stateDir ? "/var/lib/auto-suspend",
  runtimeDir ? "/run/auto-suspend",
  # Discharge-rate model; see the `predictive` options in auto-suspend.nix.
  predictive ? {
    enable = true;
    emptyPercent = 5;
    lowMinutes = 6;
    criticalMinutes = 3;
    windowSeconds = 120;
  },
}:

pkgs.writeShellScript "check-battery" ''
  set -euo pipefail

  STATE_DIR="''${AUTO_SUSPEND_STATE_DIR:-${stateDir}}"
  STATE_FILE="$STATE_DIR/last-action"
  NOTIFIED_FILE="$STATE_DIR/notified-levels"
  SSH_PROMPT_FILE="$STATE_DIR/ssh-prompt"
  RUNTIME_DIR="''${AUTO_SUSPEND_RUNTIME_DIR:-${runtimeDir}}"
  SAMPLES_FILE="$RUNTIME_DIR/discharge-samples"
  SSH_PROMPT_UNIT=${pkgs.lib.escapeShellArg sshPromptUnit}
  ${pkgs.coreutils}/bin/mkdir -p "$STATE_DIR"

  # Timer runs and power events can overlap; only one check decides at a time.
  exec 9>"$STATE_DIR/check.lock"
  if ! ${pkgs.util-linux}/bin/flock -n 9; then
    echo "Another battery check is running, skipping"
    exit 0
  fi

  # logind refuses a request while another sleep is in progress. That sleep
  # already does what we asked, so the refusal counts as success.
  request_sleep() {
    local verb=$1 output
    if output=$(${pkgs.systemd}/bin/systemctl "$verb" 2>&1); then
      echo "Successfully initiated $verb"
      return 0
    fi
    [ -z "$output" ] || echo "$output"
    case "$output" in
      *"already in progress"*)
        echo "A sleep operation is already in progress"
        return 0
        ;;
    esac
    return 1
  }

  # Tries each verb in order. Plain suspend comes last: it never hibernates,
  # so it is only for hosts that cannot hibernate at all.
  do_sleep() {
    local verb
    for verb in "$@"; do
      if request_sleep "$verb"; then
        return 0
      fi
      echo "$verb failed"
    done
    return 1
  }

  CHECK_STARTED=$(${pkgs.coreutils}/bin/date +%s)

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
    ${pkgs.coreutils}/bin/rm -f "$STATE_FILE" "$NOTIFIED_FILE" "$SSH_PROMPT_FILE" "$SAMPLES_FILE"
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

  # The battery snapshot is only valid if the system did not sleep since
  # this check started; the check after resume decides again.
  exit_if_slept() {
    local marker stamp
    for marker in "$RUNTIME_DIR/last-sleep" "$RUNTIME_DIR/last-resume"; do
      [ -f "$marker" ] || continue
      stamp=$(${pkgs.coreutils}/bin/cat "$marker")
      case "$stamp" in
        "" | *[!0-9]*) continue ;;
      esac
      if [ "$stamp" -ge "$CHECK_STARTED" ]; then
        echo "System slept during this check; the next check decides with fresh data"
        exit 0
      fi
    done
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

  # Discharge-rate model. Under heavy load the gauge can fall 5%/min and the
  # battery can cut out well above 0%, so fixed levels alone come too late.
  # Each check records (time, charge %); the drop over the last
  # windowSeconds projects the minutes left until emptyPercent.
  NOW=$(${pkgs.coreutils}/bin/date +%s)
  PERCENT_EXACT=$(${pkgs.gawk}/bin/awk -v e="$ENERGY" -v f="$ENERGY_FULL" -v p="$PERCENTAGE" \
    'BEGIN { if (e != "" && f > 0) printf "%.3f", 100 * e / f; else printf "%.3f", p }')
  PREDICTED_LOW=0
  PREDICTED_CRITICAL=0
  DRAIN_PER_MIN=""
  MINUTES_LEFT=""
  ${pkgs.lib.optionalString predictive.enable ''
    ${pkgs.coreutils}/bin/mkdir -p "$RUNTIME_DIR"
    next_samples=$(${pkgs.coreutils}/bin/mktemp "$RUNTIME_DIR/samples.XXXXXX")
    if [ -f "$SAMPLES_FILE" ]; then
      # Drop old samples, and all of them after a gap (sleep, or no checks):
      # a rate across a gap means nothing.
      ${pkgs.gawk}/bin/awk -v now="$NOW" -v keep=${toString (predictive.windowSeconds * 2)} '
        { t[NR] = $1; line[NR] = $0 }
        END {
          if (NR == 0 || now - t[NR] > 300) exit
          for (i = 1; i <= NR; i++) if (now - t[i] <= keep) print line[i]
        }' "$SAMPLES_FILE" > "$next_samples"
    fi

    PREDICTION=$(${pkgs.gawk}/bin/awk -v now="$NOW" -v p="$PERCENT_EXACT" \
      -v window=${toString predictive.windowSeconds} -v empty=${toString predictive.emptyPercent} '
        !found && now - $1 <= window && now - $1 >= 45 { t = $1; old = $2; found = 1 }
        END {
          if (!found) exit
          rate = (old - p) / (now - t) * 60
          if (rate <= 0) exit
          left = (p - empty) / rate
          if (left < 0) left = 0
          printf "%.2f %.1f\n", rate, left
        }' "$next_samples")

    printf '%s %s\n' "$NOW" "$PERCENT_EXACT" >> "$next_samples"
    ${pkgs.coreutils}/bin/mv "$next_samples" "$SAMPLES_FILE"

    if [ -n "$PREDICTION" ]; then
      read -r DRAIN_PER_MIN MINUTES_LEFT <<< "$PREDICTION"
      echo "Draining $DRAIN_PER_MIN%/min: about $MINUTES_LEFT min until ${toString predictive.emptyPercent}%"
      if ${pkgs.gawk}/bin/awk -v m="$MINUTES_LEFT" 'BEGIN { exit !(m <= ${toString predictive.criticalMinutes}) }'; then
        PREDICTED_CRITICAL=1
      fi
      if ${pkgs.gawk}/bin/awk -v m="$MINUTES_LEFT" 'BEGIN { exit !(m <= ${toString predictive.lowMinutes}) }'; then
        PREDICTED_LOW=1
      fi
    fi
  ''}

  notify_fast_drain() {
    ${sendNotificationScript} "Low Battery" "Battery draining at $DRAIN_PER_MIN%/min ($PERCENTAGE%, about $MINUTES_LEFT min left). Suspending now." "critical"
  }

  # Read last action from state file
  # Format: "<low|critical> <epoch>"; older files hold only the level.
  LAST_ACTION=""
  LAST_ACTION_TIME=0
  if [ -f "$STATE_FILE" ]; then
    read -r LAST_ACTION LAST_ACTION_TIME < "$STATE_FILE" || true
  fi
  case "$LAST_ACTION_TIME" in
    "" | *[!0-9]*) LAST_ACTION_TIME=0 ;;
  esac
  LAST_RESUME=0
  if [ -f "$RUNTIME_DIR/last-resume" ]; then
    LAST_RESUME=$(${pkgs.coreutils}/bin/cat "$RUNTIME_DIR/last-resume")
  fi
  case "$LAST_RESUME" in
    "" | *[!0-9]*) LAST_RESUME=0 ;;
  esac

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
        message="Battery critically low at $PERCENTAGE%! System will hibernate again in a few minutes unless plugged in."
      else
        message="Battery critically low at $PERCENTAGE%! System will hibernate immediately."
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

  # Critical level: UPower says "critical", energy below the calculated
  # threshold, or the drain rate leaves under criticalMinutes.
  CRITICAL_BY_LEVEL=0
  if [ "$CAPACITY_LEVEL" = "critical" ] || ([ -n "$ENERGY" ] && [ "$(echo "$ENERGY < $CRITICAL_ENERGY_THRESHOLD" | ${pkgs.bc}/bin/bc)" = "1" ]); then
    CRITICAL_BY_LEVEL=1
  fi
  if [ "$CRITICAL_BY_LEVEL" = 1 ] || [ "$PREDICTED_CRITICAL" = 1 ]; then
    # After a critical action, a resumed system gets criticalRepeatSeconds
    # to be plugged in; then the action repeats.
    since=$LAST_ACTION_TIME
    if [ "$LAST_RESUME" -gt "$since" ]; then
      since=$LAST_RESUME
    fi
    if [ "$LAST_ACTION" = "critical" ] && [ $((NOW - since)) -lt ${toString criticalRepeatSeconds} ]; then
      echo "Critical action ran or system resumed $((NOW - since))s ago; repeating after ${toString criticalRepeatSeconds}s"
      exit 0
    fi

    # Critical never waits for SSH sessions.
    stop_ssh_prompt
    exit_unless_discharging
    exit_if_slept
    if [ "$CRITICAL_BY_LEVEL" = 1 ]; then
      echo "Battery critical (capacity-level=$CAPACITY_LEVEL or $ENERGY Wh < $CRITICAL_ENERGY_THRESHOLD Wh [${toString criticalLevel}%]), hibernating"
    else
      echo "Battery draining at $DRAIN_PER_MIN%/min, about $MINUTES_LEFT min left, hibernating"
      notify_fast_drain
    fi
    printf 'critical %s\n' "$NOW" > "$STATE_FILE"
    # Write the image now, while charge remains.
    do_sleep hibernate suspend-then-hibernate suspend
    exit 0
  fi

  # Low level: UPower says "low", energy below the calculated threshold, or
  # the drain rate leaves under lowMinutes.
  LOW_BY_LEVEL=0
  if [ "$CAPACITY_LEVEL" = "low" ] || ([ -n "$ENERGY" ] && [ "$(echo "$ENERGY < $LOW_ENERGY_THRESHOLD" | ${pkgs.bc}/bin/bc)" = "1" ]); then
    LOW_BY_LEVEL=1
  fi
  if [ "$LOW_BY_LEVEL" = 1 ] || [ "$PREDICTED_LOW" = 1 ]; then
    if [ "$LAST_ACTION" != "low" ] && [ "$LAST_ACTION" != "critical" ]; then
      if ! ssh_prompt_allows_suspend; then
        exit 0
      fi
      exit_unless_discharging
      exit_if_slept
      if [ "$LOW_BY_LEVEL" = 1 ]; then
        echo "Battery low (capacity-level=$CAPACITY_LEVEL or $ENERGY Wh < $LOW_ENERGY_THRESHOLD Wh [${toString lowLevel}%]), attempting suspend-then-hibernate"
      else
        echo "Battery draining at $DRAIN_PER_MIN%/min, about $MINUTES_LEFT min left, attempting suspend-then-hibernate"
        notify_fast_drain
      fi
      printf 'low %s\n' "$NOW" > "$STATE_FILE"
      do_sleep suspend-then-hibernate hibernate suspend
    else
      # The user woke the system after the low action; the critical action
      # still applies.
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
