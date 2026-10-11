{
  brightnessctl,
  coreutils,
  gnome-icon-theme,
  lib,
  libnotify,
  systemd,
  writeShellApplication,
}:

writeShellApplication {
  name = "brightness-notify";

  runtimeInputs = [
    brightnessctl
    coreutils
    libnotify
    systemd
  ];

  # The user-facing level is logical: 0-100 in 4% steps. At or above the knee,
  # the hardware percentage equals the level. Below the knee, it falls linearly
  # from the knee to dim_percent at dim_level. Level 0 sets it to 0, so the
  # screen is black. The laptop backlight and, through brightness-sync,
  # external monitors' DDC/CI brightness follow the hardware percentage. A
  # software factor applied to every output through wl-gammarelay-rs is the
  # hardware percentage divided by the knee, so software carries more of the
  # dimming as the level approaches 0.
  #
  # The level is read back from the backlight, so the mapping must stay
  # invertible on the step grid.
  #
  # The factor is published at $XDG_RUNTIME_DIR/brightness-notify/software-brightness.
  # daylight-display multiplies it into its own brightness; when
  # daylight-display is not running, this script applies it directly.
  text = ''
    set -euo pipefail

    step=4
    knee=60
    dim_level=4
    dim_percent=24

    # Below the knee, hardware percent = knee - (knee - level) * slope / run.
    run=$(( knee - dim_level ))
    slope=$(( knee - dim_percent ))

    action="''${1:-}"
    case "$action" in
      up | down | sync) ;;
      *)
        printf 'usage: brightness-notify up|down|sync\n' >&2
        exit 2
        ;;
    esac

    if ! status="$(brightnessctl --class=backlight --machine-readable info 2>/dev/null)"; then
      if [ "$action" = sync ]; then
        exit 0
      fi
      printf 'brightness-notify: no backlight device\n' >&2
      exit 1
    fi
    IFS=, read -r _device _class raw _percent max <<< "$status"
    if (( 100 * raw >= knee * max )); then
      nearest_step=$(( (200 * raw + step * max) / (2 * step * max) ))
    else
      # Invert the hardware mapping, then round to the nearest step.
      level_num=$(( knee * slope * max - (knee * max - 100 * raw) * run ))
      level_den=$(( slope * max ))
      nearest_step=$(( (2 * level_num + step * level_den) / (2 * step * level_den) ))
      nearest_step=$(( nearest_step < 0 ? 0 : nearest_step ))
    fi
    level=$(( nearest_step * step ))

    case "$action" in
      up)
        level=$(( level + step > 100 ? 100 : level + step ))
        title="Brightness up"
        ;;
      down)
        level=$(( level - step < 0 ? 0 : level - step ))
        title="Brightness down"
        ;;
    esac

    # Hardware percent, scaled by run to stay integral.
    if (( level == 0 )); then
      hardware=0
    elif (( level >= knee )); then
      hardware=$(( level * run ))
    else
      hardware=$(( knee * run - (knee - level) * slope ))
    fi

    if [ "$action" != sync ]; then
      brightnessctl --class=backlight --quiet set \
        "$(( (2 * hardware * max + 100 * run) / (200 * run) ))"
    fi

    permille=$(( level >= knee ? 1000 : hardware * 1000 / (knee * run) ))
    factor="$(printf '%d.%03d' $(( permille / 1000 )) $(( permille % 1000 )))"

    state_dir="''${XDG_RUNTIME_DIR:?}/brightness-notify"
    mkdir -p "$state_dir"
    printf '%s\n' "$factor" > "$state_dir/software-brightness.tmp"
    mv -f "$state_dir/software-brightness.tmp" "$state_dir/software-brightness"

    if systemctl --user --quiet is-active daylight-display.service; then
      systemctl --user kill --kill-whom=main --signal=SIGUSR1 daylight-display.service \
        || printf 'brightness-notify: could not signal daylight-display\n' >&2
    elif busctl --user status rs.wl-gammarelay >/dev/null 2>&1; then
      busctl --user set-property rs.wl-gammarelay / rs.wl.gammarelay Brightness d "$factor" \
        || printf 'brightness-notify: could not set software brightness\n' >&2
    fi

    if [ "$action" = sync ]; then
      exit 0
    fi

    if systemctl --user --quiet is-active brightness-sync.service; then
      systemctl --user kill --kill-whom=main --signal=SIGUSR1 brightness-sync.service \
        || printf 'brightness-notify: could not signal brightness-sync\n' >&2
    fi

    if [ "$level" -lt 25 ]; then
      icon="${gnome-icon-theme}/share/icons/gnome/48x48/status/stock_weather-night-clear.png"
      body="$level% - moonlit"
    elif [ "$level" -lt 75 ]; then
      icon="${gnome-icon-theme}/share/icons/gnome/48x48/status/weather-few-clouds-night.png"
      body="$level% - easy glow"
    else
      icon="${gnome-icon-theme}/share/icons/gnome/48x48/status/sunny.png"
      body="$level% - bright and clear"
    fi

    notify-send \
      --app-name="JohnOS Brightness" \
      --icon="$icon" \
      --expire-time=1400 \
      --hint=string:x-canonical-private-synchronous:brightness \
      --hint="int:value:$level" \
      "$title" \
      "$body" \
      || true
  '';

  meta = with lib; {
    description = "Adjust display brightness across backlight and software dimming and show an on-screen notification";
    license = licenses.mit;
    mainProgram = "brightness-notify";
    platforms = platforms.linux;
  };
}
