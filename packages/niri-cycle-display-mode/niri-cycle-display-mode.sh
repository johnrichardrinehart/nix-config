#!/usr/bin/env bash
set -euo pipefail

command="${1:-cycle}"

state_dir="${XDG_RUNTIME_DIR:-/tmp}/johnos-niri-display-mode"
mirror_pid_file="$state_dir/wl-mirror.pids"
mirror_source_file="$state_dir/wl-mirror.source"
mirror_positions_file="$state_dir/wl-mirror.positions.json"
f9_picker_pid_file="$state_dir/f9-picker.pid"
single_migrate_state_file="$state_dir/single-migrate-state.json"
mirror_target_position_base=100000
display_icon="@display_icon@"

notify_display() {
  local title="$1"
  local body="${2:-}"

  notify-send \
    --app-name="JohnOS Display" \
    --icon="$display_icon" \
    --expire-time=1600 \
    --hint=string:x-canonical-private-synchronous:display \
    "$title" \
    "$body" || true
}

active_outputs_map_json() {
  printf '%s\n' "${active_outputs[@]}" |
    jq -Rn '[inputs | select(. != "")] | map({key: ., value: true}) | from_entries'
}

clear_migration_state() {
  rm -f "$single_migrate_state_file"
}

load_workspaces() {
  if ! workspaces_json="$(niri msg --json workspaces 2>/dev/null)"; then
    return 1
  fi
}

is_internal_output() {
  case "$1" in
  eDP-* | LVDS-* | DSI-*) return 0 ;;
  *) return 1 ;;
  esac
}

load_outputs() {
  if ! outputs_json="$(niri msg --json outputs 2>/dev/null)"; then
    return 1
  fi

  mapfile -t outputs < <(jq -r 'to_entries | map(.value.name // .key) | sort | .[]' <<<"$outputs_json")
  mapfile -t active_outputs < <(jq -r 'to_entries[] | select(.value.logical != null) | .value.name // .key' <<<"$outputs_json")

  single_outputs=()
  internal_outputs=()
  external_outputs=()
  active_external_outputs=()

  for output in "${outputs[@]}"; do
    if is_internal_output "$output"; then
      internal_outputs+=("$output")
    else
      external_outputs+=("$output")
      single_outputs+=("$output")
      if output_is_active "$output"; then
        active_external_outputs+=("$output")
      fi
    fi
  done
  for output in "${internal_outputs[@]}"; do
    single_outputs+=("$output")
  done
}

first_single_target() {
  printf '%s\n' "${single_outputs[0]}"
}

next_single_target() {
  current="$1"

  for i in "${!single_outputs[@]}"; do
    if [ "${single_outputs[$i]}" = "$current" ]; then
      next_index=$((i + 1))
      if [ "$next_index" -lt "${#single_outputs[@]}" ]; then
        printf '%s\n' "${single_outputs[$next_index]}"
        return 0
      fi

      return 1
    fi
  done

  first_single_target
}

mirror_is_active() {
  [ -f "$mirror_pid_file" ] || return 1

  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    if kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  done <"$mirror_pid_file"

  return 1
}

save_mirror_positions() {
  local tmp_positions

  mkdir -p "$state_dir"
  tmp_positions="$(mktemp "$state_dir/wl-mirror.positions.XXXXXX")"
  if niri msg --json outputs 2>/dev/null |
    jq '[
      to_entries[]
      | select(.value.logical != null)
      | {
          output: (.value.name // .key),
          x: .value.logical.x,
          y: .value.logical.y
        }
    ]' >"$tmp_positions"; then
    mv "$tmp_positions" "$mirror_positions_file"
  else
    rm -f "$tmp_positions"
    return 1
  fi
}

restore_mirror_positions() {
  local decoded output x y

  [ -f "$mirror_positions_file" ] || return 0

  while IFS= read -r entry; do
    decoded="$(printf '%s' "$entry" | base64 -d)"
    output="$(jq -r '.output' <<<"$decoded")"
    x="$(jq -r '.x' <<<"$decoded")"
    y="$(jq -r '.y' <<<"$decoded")"
    niri msg output "$output" position set -- "$x" "$y" || true
  done < <(jq -r '.[] | @base64' "$mirror_positions_file")

  rm -f "$mirror_positions_file"
}

mirror_processes_alive() {
  local pid

  [ -f "$mirror_pid_file" ] || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null && return 0
  done <"$mirror_pid_file"
  return 1
}

stop_mirror() {
  local deadline pid

  if [ -f "$mirror_pid_file" ]; then
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      kill "$pid" 2>/dev/null || true
    done <"$mirror_pid_file"

    deadline=$((SECONDS + 2))
    while [ "$SECONDS" -lt "$deadline" ] && mirror_processes_alive; do
      sleep 0.05
    done

    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      kill -KILL "$pid" 2>/dev/null || true
    done <"$mirror_pid_file"
  fi

  restore_mirror_positions
  rm -f "$mirror_pid_file" "$mirror_source_file"
}

workspace_exists() {
  handle="$1"

  load_workspaces || return 1
  jq -e --arg handle "$handle" 'any(.[]; .name == $handle)' <<<"$workspaces_json" >/dev/null
}

restore_workspace_name() {
  handle="$1"
  original_name="$2"

  if [ -n "$original_name" ]; then
    niri msg action set-workspace-name --workspace "$handle" "$original_name" || true
  else
    niri msg action unset-workspace-name "$handle" || true
  fi
}

restore_migrated_workspaces() {
  [ -f "$single_migrate_state_file" ] || return 0

  load_outputs || return 0
  active_map="$(active_outputs_map_json)"

  mapfile -t restore_entries < <(
    jq -r --argjson active "$active_map" '
      .workspaces
      | sort_by(.original_output, .original_idx)
      | .[]
      | select($active[.original_output] == true)
      | @base64
    ' "$single_migrate_state_file" 2>/dev/null || true
  )

  [ "${#restore_entries[@]}" -gt 0 ] || return 0

  restored_handles=()
  for entry in "${restore_entries[@]}"; do
    decoded="$(printf '%s' "$entry" | base64 -d)"
    handle="$(jq -r '.handle' <<<"$decoded")"
    original_output="$(jq -r '.original_output' <<<"$decoded")"
    original_idx="$(jq -r '.original_idx' <<<"$decoded")"
    original_name="$(jq -r '.original_name // ""' <<<"$decoded")"

    workspace_exists "$handle" || {
      restored_handles+=("$handle")
      continue
    }

    niri msg action move-workspace-to-monitor --reference "$handle" "$original_output" || continue
    sleep 0.1
    niri msg action move-workspace-to-index --reference "$handle" "$original_idx" || true
    restore_workspace_name "$handle" "$original_name"
    restored_handles+=("$handle")
  done

  [ "${#restored_handles[@]}" -gt 0 ] || return 0

  restored_json="$(printf '%s\n' "${restored_handles[@]}" |
    jq -Rn '[inputs | select(. != "")]')"
  tmp_state="$(mktemp "$state_dir/single-migrate-state.XXXXXX")"
  if jq --argjson restored "$restored_json" '
    .workspaces |= map(select(.handle as $handle | ($restored | index($handle) | not)))
    | select(.workspaces | length > 0)
  ' "$single_migrate_state_file" >"$tmp_state"; then
    if [ -s "$tmp_state" ]; then
      mv "$tmp_state" "$single_migrate_state_file"
    else
      rm -f "$tmp_state" "$single_migrate_state_file"
    fi
  else
    rm -f "$tmp_state"
  fi
}

isolate_mirror_targets() {
  source_output="$1"
  target_index=1

  for output in "${outputs[@]}"; do
    if [ "$output" != "$source_output" ]; then
      niri msg output "$output" position set "$((mirror_target_position_base * target_index))" 0 || true
      target_index=$((target_index + 1))
    fi
  done
}

keep_mirror_source_focused() {
  local source_output

  [ -f "$mirror_source_file" ] || return 0
  IFS= read -r source_output <"$mirror_source_file" || return 0
  [ -n "$source_output" ] || return 0
  output_is_active "$source_output" || return 0

  isolate_mirror_targets "$source_output"
  niri msg action focus-monitor "$source_output" || true
}

apply_extend() {
  stop_mirror

  [ "${#outputs[@]}" -gt 0 ] || return 0

  for output in "${outputs[@]}"; do
    niri msg output "$output" on || true
  done

  sleep 0.2
  niri msg action load-config-file || true
  sleep 0.2
  restore_migrated_workspaces
  clear_migration_state
  notify_display "Displays extended" "${#outputs[@]} outputs active"
}

mirror_window_id_on_output() {
  local pid="$1"
  local target_output="$2"
  local window_id workspace_id

  read -r window_id workspace_id < <(
    niri msg --json windows 2>/dev/null |
      jq -r --argjson pid "$pid" \
        '.[] | select(.pid == $pid) | [.id, .workspace_id] | @tsv' |
      head -n 1
  )
  [ -n "$window_id" ] && [ -n "$workspace_id" ] || return 1

  niri msg --json workspaces 2>/dev/null |
    jq -e --argjson workspace_id "$workspace_id" --arg output "$target_output" \
      'any(.[]; .id == $workspace_id and .output == $output)' >/dev/null || return 1
  printf '%s\n' "$window_id"
}

start_mirror_target() {
  local source_output="$1"
  local target_output="$2"
  local log_file pid ready window_id

  log_file="$state_dir/wl-mirror-${target_output}.log"
  for _ in 1 2 3; do
    : >"$log_file"
    nohup wl-mirror --fullscreen-output "$target_output" "$source_output" \
      >"$log_file" 2>&1 &
    pid="$!"
    ready=false
    for _ in $(seq 1 40); do
      if ! kill -0 "$pid" 2>/dev/null; then
        break
      fi
      window_id="$(mirror_window_id_on_output "$pid" "$target_output" || true)"
      if [ -n "$window_id" ]; then
        niri msg action focus-window --id "$window_id" >/dev/null || true
        ready=true
        break
      fi
      sleep 0.05
    done
    if [ "$ready" = true ]; then
      printf '%s\n' "$pid" >>"$mirror_pid_file"
      return 0
    fi
    kill "$pid" 2>/dev/null || true
    sleep 0.1
  done

  notify_display "Display mirror failed" \
    "Could not attach mirror to $target_output; see $log_file"
  return 1
}

apply_mirror() {
  source_output="$1"
  stop_mirror
  clear_migration_state

  [ "${#outputs[@]}" -gt 1 ] || return 0

  for output in "${outputs[@]}"; do
    niri msg output "$output" on || true
  done

  sleep 0.2
  niri msg action load-config-file || true
  sleep 0.2
  save_mirror_positions
  isolate_mirror_targets "$source_output"
  : >"$mirror_pid_file"
  printf '%s\n' "$source_output" >"$mirror_source_file"

  mirror_failures=0
  for output in "${outputs[@]}"; do
    if [ "$output" != "$source_output" ]; then
      start_mirror_target "$source_output" "$output" || mirror_failures=$((mirror_failures + 1))
    fi
  done

  niri msg action focus-monitor "$source_output" || true
  if [ "$mirror_failures" -eq 0 ]; then
    notify_display "Displays mirrored" "Source: $source_output"
  else
    notify_display "Display mirror incomplete" "$mirror_failures target(s) failed"
  fi
}

apply_single_outputs() {
  target="$1"
  stop_mirror

  niri msg output "$target" on
  sleep 0.2

  for output in "${outputs[@]}"; do
    if [ "$output" != "$target" ]; then
      niri msg output "$output" off || true
    fi
  done

  niri msg action focus-monitor "$target" || true
}

apply_single_isolated() {
  target="$1"
  clear_migration_state
  apply_single_outputs "$target"
  notify_display "Display isolated" "$target"
}

apply_single_migrate() {
  target="$1"
  stop_mirror
  restore_migrated_workspaces
  clear_migration_state

  load_outputs || return 0
  load_workspaces || return 0
  mkdir -p "$state_dir"

  session_id="$(date +%s)-$$"
  active_map="$(active_outputs_map_json)"
  migrate_state="$(
    jq -cn \
      --arg target "$target" \
      --arg session "$session_id" \
      '{version: 1, target: $target, session: $session, workspaces: []}'
  )"

  mapfile -t migrate_entries < <(
    jq -r --arg target "$target" --argjson active "$active_map" '
      .[]
      | select(.output != $target)
      | select($active[.output] == true)
      | @base64
    ' <<<"$workspaces_json"
  )

  niri msg output "$target" on
  sleep 0.2

  for entry in "${migrate_entries[@]}"; do
    decoded="$(printf '%s' "$entry" | base64 -d)"
    workspace_id="$(jq -r '.id' <<<"$decoded")"
    original_idx="$(jq -r '.idx' <<<"$decoded")"
    original_output="$(jq -r '.output' <<<"$decoded")"
    original_name="$(jq -r '.name // ""' <<<"$decoded")"
    handle="__johnos_migrated_${session_id}_${workspace_id}"

    niri msg action focus-monitor "$original_output" || true
    niri msg action set-workspace-name --workspace "$original_idx" "$handle" || continue

    migrate_state="$(
      jq \
        --arg handle "$handle" \
        --argjson id "$workspace_id" \
        --arg output "$original_output" \
        --argjson idx "$original_idx" \
        --arg name "$original_name" \
        '.workspaces += [{
          handle: $handle,
          id: $id,
          original_output: $output,
          original_idx: $idx,
          original_name: (if $name == "" then null else $name end)
        }]' <<<"$migrate_state"
    )"
  done

  mapfile -t migrate_handles < <(jq -r '.workspaces[].handle' <<<"$migrate_state")
  for handle in "${migrate_handles[@]}"; do
    niri msg action move-workspace-to-monitor --reference "$handle" "$target" || true
  done

  if jq -e '.workspaces | length > 0' <<<"$migrate_state" >/dev/null; then
    printf '%s\n' "$migrate_state" >"$single_migrate_state_file"
  fi

  apply_single_outputs "$target"
  notify_display "Display migrated" "$target"
}

output_is_active() {
  candidate="$1"

  for output in "${active_outputs[@]}"; do
    if [ "$output" = "$candidate" ]; then
      return 0
    fi
  done

  return 1
}

ensure_internal_when_alone() {
  load_outputs || return 0
  [ "${#internal_outputs[@]}" -gt 0 ] || return 0
  [ "${#active_external_outputs[@]}" -eq 0 ] || return 0

  internal_output="${internal_outputs[0]}"
  stop_mirror

  if ! output_is_active "$internal_output"; then
    apply_single_outputs "$internal_output" || return 0
  fi

  if [ "$(focused_output || true)" != "$internal_output" ]; then
    niri msg action focus-monitor "$internal_output" || true
  fi
}

focused_output() {
  niri msg --json focused-output 2>/dev/null | jq -r '.name // empty'
}

json_status() {
  text="$1"
  class="$2"

  jq -cn --arg text "$text" --arg class "$class" \
    '{text: $text, tooltip: $text, class: $class}'
}

display_status() {
  load_outputs || exit 1
  [ "${#outputs[@]}" -gt 1 ] || exit 1

  if mirror_is_active; then
    json_status "mirror" "mirror"
    exit 0
  fi

  current_output="$(focused_output || true)"
  if [ -z "$current_output" ] || ! output_is_active "$current_output"; then
    current_output="${active_outputs[0]:-}"
  fi

  if [ -z "$current_output" ]; then
    json_status "(no output)" "unknown"
  elif [ "${#active_outputs[@]}" -gt 1 ]; then
    json_status "$current_output (extend)" "extend"
  elif [ -f "$single_migrate_state_file" ]; then
    json_status "$current_output (migrate)" "single-migrate"
  else
    json_status "$current_output (isolated)" "single-isolated"
  fi
}

current_mirror_source() {
  local source_output

  if [ -f "$mirror_source_file" ] && IFS= read -r source_output <"$mirror_source_file"; then
    if [ -n "$source_output" ] && output_is_active "$source_output"; then
      printf '%s\n' "$source_output"
      return 0
    fi
  fi

  focused_output
}

picker_is_active() {
  [ -f "$f9_picker_pid_file" ] || return 1

  if IFS= read -r pid <"$f9_picker_pid_file"; then
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
  fi

  rm -f "$f9_picker_pid_file"
  return 1
}

picker_output_is_valid() {
  local candidate="$1"
  local output

  for output in "${outputs[@]}"; do
    [ "$output" = "$candidate" ] && return 0
  done
  return 1
}

picker_read_output() {
  local action="$1"
  local candidate

  candidate="$(fuzzel --dmenu --prompt-only "$action output: ")" || return 1
  if picker_output_is_valid "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  notify_display "Unknown display" "$candidate"
  return 1
}

write_picker_config() {
  local destination="$1"
  local user_config="${XDG_CONFIG_HOME:-$HOME/.config}/fuzzel/fuzzel.ini"

  if [ -r "$user_config" ]; then
    cat "$user_config" >"$destination"
  else
    : >"$destination"
  fi
  cat >>"$destination" <<'EOF'

[key-bindings]
execute-or-next=Control+Shift+F12
custom-1=Tab
EOF
}

display_picker() {
  picker_is_active && return 0

  load_outputs || exit 0
  [ "${#outputs[@]}" -gt 1 ] || exit 0

  if mirror_is_active; then
    source_output="$(current_mirror_source || true)"
    if [ -n "$source_output" ] && output_is_active "$source_output"; then
      niri msg action focus-monitor "$source_output" || true
      sleep 0.1
    fi
  fi

  mkdir -p "$state_dir"
  printf '%s\n' "$$" >"$f9_picker_pid_file"
  trap 'rm -f "$f9_picker_pid_file"' EXIT
  picker_config="$(mktemp "$state_dir/fuzzel-picker.XXXXXX.ini")"
  trap 'rm -f "$f9_picker_pid_file" "$picker_config"' EXIT
  write_picker_config "$picker_config"

  picker_mode=enumerated
  while true; do
    if [ "$picker_mode" = enumerated ]; then
      menu="Extend"
      for output in "${outputs[@]}"; do
        menu="$menu
Single isolated: $output
Single migrate: $output
Mirror: $output"
      done
      prompt="Display [Tab: templates]: "
    else
      menu="Extend
Single isolated: OUTPUT
Single migrate: OUTPUT
Mirror: OUTPUT"
      prompt="Display template [Tab: all choices]: "
    fi

    set +e
    selection="$(printf '%s\n' "$menu" | fuzzel --config "$picker_config" --dmenu --only-match --prompt "$prompt")"
    picker_status="$?"
    set -e
    if [ "$picker_status" -eq 10 ]; then
      if [ "$picker_mode" = enumerated ]; then
        picker_mode=templates
      else
        picker_mode=enumerated
      fi
      continue
    fi
    [ "$picker_status" -eq 0 ] || exit 0
    break
  done

  case "$selection" in
  Extend)
    apply_extend
    ;;
  "Single isolated: OUTPUT")
    target="$(picker_read_output "Single isolated")" || exit 0
    apply_single_isolated "$target"
    ;;
  "Single migrate: OUTPUT")
    target="$(picker_read_output "Single migrate")" || exit 0
    apply_single_migrate "$target"
    ;;
  "Mirror: OUTPUT")
    source_output="$(picker_read_output "Mirror source")" || exit 0
    apply_mirror "$source_output"
    ;;
  "Single isolated: "*)
    apply_single_isolated "${selection#Single isolated: }"
    ;;
  "Single migrate: "*)
    apply_single_migrate "${selection#Single migrate: }"
    ;;
  "Mirror: "*)
    apply_mirror "${selection#Mirror: }"
    ;;
  esac
}

watch_outputs() {
  while true; do
    load_outputs && keep_mirror_source_focused || true
    ensure_internal_when_alone || true
    sleep 2
  done
}

cycle_display_mode() {
  load_outputs || exit 0
  [ "${#outputs[@]}" -gt 0 ] || exit 0

  if mirror_is_active; then
    apply_extend
  elif [ "${#outputs[@]}" -eq 1 ]; then
    if [ "${#active_outputs[@]}" -eq 0 ]; then
      apply_single_isolated "$(first_single_target)"
    fi
  elif [ "${#active_outputs[@]}" -gt 1 ]; then
    apply_single_isolated "$(first_single_target)"
  elif [ "${#active_outputs[@]}" -eq 1 ]; then
    current_output="${active_outputs[0]}"
    if next_output="$(next_single_target "$current_output")"; then
      apply_single_isolated "$next_output"
    else
      apply_mirror "$current_output"
    fi
  else
    apply_single_isolated "$(first_single_target)"
  fi
}

case "$command" in
pick) display_picker ;;
status) display_status ;;
--watch) watch_outputs ;;
single-isolated)
  target="${2:-}"
  [ -n "$target" ] || {
    echo "Usage: niri-cycle-display-mode single-isolated <output>" >&2
    exit 2
  }
  load_outputs || exit 0
  apply_single_isolated "$target"
  ;;
mirror)
  source_output="${2:-}"
  load_outputs || exit 0
  if [ -z "$source_output" ] || ! output_is_active "$source_output"; then
    source_output="$(focused_output || true)"
  fi
  [ -n "$source_output" ] || source_output="${active_outputs[0]:-$(first_single_target)}"
  apply_mirror "$source_output"
  ;;
single-migrate)
  target="${2:-}"
  [ -n "$target" ] || {
    echo "Usage: niri-cycle-display-mode single-migrate <output>" >&2
    exit 2
  }
  load_outputs || exit 0
  apply_single_migrate "$target"
  ;;
cycle) cycle_display_mode ;;
*)
  echo "Usage: niri-cycle-display-mode [pick|status|--watch|cycle|mirror [source-output]|single-isolated <output>|single-migrate <output>]" >&2
  exit 2
  ;;
esac
