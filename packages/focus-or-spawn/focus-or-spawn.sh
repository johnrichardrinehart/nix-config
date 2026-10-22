#!/usr/bin/env bash
set -euo pipefail

# focus-or-spawn: application launcher that raises single-window apps.
#
# Without arguments it opens fuzzel with itself as the launch prefix. fuzzel
# then runs `focus-or-spawn EXEC...` with the chosen entry's Desktop File ID
# in DESKTOP_ENTRY_ID. An entry declaring SingleMainWindow=true (Desktop
# Entry spec 1.5; KeePassXC, Telegram) has its existing window focused,
# because a second launch only messages the running instance, which cannot
# take focus on Wayland. Everything else (browsers, terminals) launches.

if [[ $# -eq 0 ]]; then
  namespace="focus-or-spawn-$$"
  FOCUS_OR_SPAWN_NAMESPACE=$namespace exec fuzzel --namespace="$namespace" --launch-prefix="$0"
fi

desktop_id=${DESKTOP_ENTRY_ID:-}

desktop_file=""
if [[ -n $desktop_id ]]; then
  IFS=: read -r -a data_dirs <<<"${XDG_DATA_HOME:-$HOME/.local/share}:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
  for data_dir in "${data_dirs[@]}"; do
    if [[ -f "$data_dir/applications/$desktop_id" ]]; then
      desktop_file=$data_dir/applications/$desktop_id
      break
    fi
  done
fi

single_main_window=""
startup_wm_class=""
if [[ -n $desktop_file ]]; then
  while IFS='=' read -r key value; do
    case "$key" in
    SingleMainWindow) single_main_window=$value ;;
    StartupWMClass) startup_wm_class=$value ;;
    esac
  done < <(awk '/^\[/ { in_entry = ($0 == "[Desktop Entry]"); next } in_entry' "$desktop_file")
fi

window_id=""
if [[ $single_main_window == "true" ]]; then
  window_id=$(niri msg --json windows | jq -r \
    --arg id "${desktop_id%.desktop}" --arg class "$startup_wm_class" '
      ($id | ascii_downcase) as $id
      | ($class | ascii_downcase) as $class
      | map(select((.app_id // "" | ascii_downcase) as $app | $app == $id or ($class != "" and $app == $class)))
      | max_by([.focus_timestamp.secs, .focus_timestamp.nanos])
      | .id // empty
    ')
fi

if [[ -z $window_id ]]; then
  exec "$@"
fi

# fuzzel's layer surface holds keyboard focus until it unmaps; focusing
# before then can leave the chosen window unfocused.
if [[ -n ${FOCUS_OR_SPAWN_NAMESPACE:-} ]]; then
  for _ in {1..25}; do
    niri msg --json layers | jq -e --arg namespace "$FOCUS_OR_SPAWN_NAMESPACE" \
      'all(.[]; .namespace != $namespace)' >/dev/null && break
    sleep 0.01
  done
fi

niri msg action focus-window --id "$window_id"
