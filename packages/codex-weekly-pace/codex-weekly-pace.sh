#!/usr/bin/env bash
set -euo pipefail

watch_mode=0
interval=30
max_snapshot_age_min="${CODEX_WEEKLY_PACE_MAX_SNAPSHOT_AGE_MIN:-60}"

while [ "$#" -gt 0 ]; do
  case "$1" in
  --watch)
    watch_mode=1
    ;;
  --interval)
    shift
    interval="$1"
    ;;
  --max-snapshot-age-min)
    shift
    max_snapshot_age_min="$1"
    ;;
  *)
    echo "Unknown argument: $1" >&2
    echo "Usage: codex-weekly-pace [--watch] [--interval SECONDS] [--max-snapshot-age-min MINUTES]" >&2
    exit 2
    ;;
  esac
  shift
done

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "codex-weekly-pace: missing required command: $1" >&2
    exit 127
  fi
}

for cmd in jq awk date find xargs mkdir; do
  require_tool "$cmd"
done

find_codex_command() {
  if [ -n "${CODEX_WEEKLY_PACE_CODEX:-}" ]; then
    printf '%s\n' "$CODEX_WEEKLY_PACE_CODEX"
    return 0
  fi

  if command -v codex-cli-nix >/dev/null 2>&1; then
    command -v codex-cli-nix
    return 0
  fi

  if command -v codex >/dev/null 2>&1; then
    command -v codex
    return 0
  fi

  return 1
}

find_app_server_weekly_limit_json() {
  local codex_cmd
  codex_cmd="$(find_codex_command)" || return 1
  local -a app_server_cmd

  if [ "${codex_cmd##*/}" = "codex-cli-nix" ]; then
    local cache_home
    cache_home="${CODEX_WEEKLY_PACE_NIX_CACHE_HOME:-/tmp/codex-weekly-pace-nix-cache}"
    mkdir -p "$cache_home"
    app_server_cmd=(env CODEX_WEEKLY_PACE_APP_SERVER=1 XDG_CACHE_HOME="$cache_home" "$codex_cmd" app-server --stdio)
  else
    app_server_cmd=(env CODEX_WEEKLY_PACE_APP_SERVER=1 "$codex_cmd" app-server --stdio)
  fi

  local output status
  set +e
  set +o pipefail
  output="$(
    {
      printf '%s\n' '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-weekly-pace","version":"0.1.0"},"capabilities":{"experimentalApi":true}}}'
      sleep 1
      printf '%s\n' '{"id":2,"method":"account/read","params":{"refreshToken":true}}'
      sleep 1
      printf '%s\n' '{"id":3,"method":"account/rateLimits/read","params":null}'
      sleep 10
    } 2>/dev/null | "${app_server_cmd[@]}" 2>/dev/null |
      jq -rc '
        select(.id == 3 and .result)
        | (.result.rateLimitsByLimitId.codex // .result.rateLimits) as $limit
        | [$limit.primary, $limit.secondary]
        | map(select(
            ((.windowDurationMins // .window_minutes) == 10080)
            and ((.usedPercent // .used_percent) != null)
            and ((.resetsAt // .resets_at) != null)
          ))
        | first
        | select(. != null)
        | {
            used_percent: (.usedPercent // .used_percent),
            window_minutes: (.windowDurationMins // .window_minutes),
            resets_at: (.resetsAt // .resets_at),
            source: "codex app-server account/rateLimits/read",
            source_timestamp: null
          }
      ' | tail -n 1
  )"
  status="$?"
  set -o pipefail
  set -e

  if [ "$status" -ne 0 ] || [ -z "$output" ]; then
    if [ -n "${CODEX_WEEKLY_PACE_DEBUG:-}" ]; then
      printf 'debug: app-server status=%s output=%s\n' "$status" "$output" >&2
    fi
    return 1
  fi

  printf '%s\n' "$output"
}

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
  C_RESET=""
fi

find_latest_snapshot_json() {
  local line
  latest_snapshot_from_files() {
    xargs -r -0 jq -rc '
        select(.type == "event_msg")
        | select(.payload.type == "token_count")
        | select(.payload.rate_limits.limit_id == "codex")
        | select(any([.payload.rate_limits.primary, .payload.rate_limits.secondary][]?;
            .window_minutes == 10080 and .used_percent != null))
        | [.timestamp, .]
      ' 2>/dev/null |
      jq -src 'sort_by(.[0]) | last | .[1]' 2>/dev/null
  }

  line="$(
    find "$HOME/.codex/sessions" -type f -name '*.jsonl' -mtime -14 -print0 2>/dev/null |
      latest_snapshot_from_files
  )"

  if [ -z "$line" ] || [ "$line" = "null" ]; then
    line="$(
      find "$HOME/.codex/sessions" -type f -name '*.jsonl' -print0 2>/dev/null |
        latest_snapshot_from_files
    )"
  fi

  if [ -z "$line" ] || [ "$line" = "null" ]; then
    return 1
  fi

  printf '%s\n' "$line"
}

find_session_weekly_limit_json() {
  local snapshot
  snapshot="$(find_latest_snapshot_json)" || return 1

  printf '%s\n' "$snapshot" |
    jq -rc '
      .timestamp as $timestamp
      | first([.payload.rate_limits.primary, .payload.rate_limits.secondary][]?
          | select(.window_minutes == 10080 and .used_percent != null and .resets_at != null))
      | select(. != null)
      | . + {
          source: "~/.codex/sessions token_count event",
          source_timestamp: $timestamp
        }
    '
}

format_minutes() {
  local mins d h m
  mins="$1"
  if [ "$mins" -lt 60 ]; then
    printf "%dm" "$mins"
    return
  fi

  if [ "$mins" -lt 1440 ]; then
    h=$((mins / 60))
    m=$((mins % 60))
    printf "%02dh %02dm" "$h" "$m"
    return
  fi

  d=$((mins / 1440))
  h=$(((mins % 1440) / 60))
  m=$((mins % 60))
  printf "%dd %02dh %02dm" "$d" "$h" "$m"
}

one_shot() {
  local weekly_limit weekly_source
  weekly_source="app-server"
  weekly_limit="$(find_app_server_weekly_limit_json)" || weekly_limit=""

  if [ -z "$weekly_limit" ] || [ "$weekly_limit" = "null" ]; then
    weekly_source="session"
    weekly_limit="$(find_session_weekly_limit_json)" || weekly_limit=""
  fi

  if [ -z "$weekly_limit" ] || [ "$weekly_limit" = "null" ]; then
    echo "No Codex weekly limit found from app-server or ~/.codex/sessions"
    return 1
  fi

  local used win_min reset now start elapsed remain on_pace gap on_pace_h source source_ts source_age
  used="$(printf '%s\n' "$weekly_limit" | jq -r '.used_percent')"
  win_min="$(printf '%s\n' "$weekly_limit" | jq -r '.window_minutes')"
  reset="$(printf '%s\n' "$weekly_limit" | jq -r '.resets_at')"
  source="$(printf '%s\n' "$weekly_limit" | jq -r '.source')"
  source_ts="$(printf '%s\n' "$weekly_limit" | jq -r '.source_timestamp // empty')"
  now="$(date +%s)"

  if [ "$weekly_source" = "session" ] && [ -n "$source_ts" ]; then
    source_age=$((now - $(date -d "$source_ts" +%s)))
    if [ "$source_age" -gt $((max_snapshot_age_min * 60)) ]; then
      printf "weekly unknown: cached Codex usage snapshot is stale by %s\n" "$(format_minutes $(((source_age + 59) / 60)))"
      printf "  cached snapshot: used %.2f%%, reset in %s\n" \
        "$used" "$(format_minutes $((((reset - now) + 59) / 60)))"
      printf "  source: %s at %s\n" "$source" "$source_ts"
      printf "  automatic app-server rate-limit read failed; run codex doctor if this persists\n"
      return 1
    fi
  fi

  start=$((reset - win_min * 60))
  elapsed=$((now - start))
  remain=$((reset - now))

  if [ "$elapsed" -lt 0 ]; then
    elapsed=0
  fi
  if [ "$remain" -lt 0 ]; then
    remain=0
  fi

  on_pace="$(awk -v e="$elapsed" -v w="$win_min" 'BEGIN { if (w <= 0) print 0; else print (e / (w * 60.0)) * 100.0 }')"
  gap="$(awk -v u="$used" -v p="$on_pace" 'BEGIN { print u - p }')"
  on_pace_h="$(awk 'BEGIN { print 100.0 / 168.0 }')"

  local sign magnitude
  sign="$(awk -v g="$gap" 'BEGIN { if (g > 0.000001) print "+"; else if (g < -0.000001) print "-"; else print "="; }')"
  magnitude="$(awk -v g="$gap" 'BEGIN { if (g < 0) g = -g; print g }')"

  printf "weekly %s%.2f%% (used %.2f%% vs. on-pace %.2f%%) | reset in %s\n" \
    "$sign" "$magnitude" \
    "$used" "$on_pace" "$(format_minutes $(((remain + 59) / 60)))"
  printf "  source: %s\n" "$source"
  if [ "$weekly_source" = "session" ] && [ -n "$source_ts" ] && [ "$source_age" -gt 300 ]; then
    printf "  snapshot: stale by %s; run /status to compare current usage\n" "$(format_minutes $(((source_age + 59) / 60)))"
  fi

  local rates rate drift eta_h eta_min remain_min label
  rates="0.1 0.25 0.5"
  remain_min=$(((remain + 59) / 60))

  for rate in $rates; do
    label="$(printf '%s%%/h' "$rate")"
    drift="$(awk -v r="$rate" -v p="$on_pace_h" 'BEGIN { print r - p }')"

    if awk -v g="$gap" 'BEGIN { exit !(g > 0.000001) }'; then
      if awk -v d="$drift" 'BEGIN { exit !(d < -0.000001) }'; then
        eta_h="$(awk -v g="$gap" -v d="$drift" 'BEGIN { print g / (-d) }')"
      else
        eta_h=""
      fi
    elif awk -v g="$gap" 'BEGIN { exit !(g < -0.000001) }'; then
      if awk -v d="$drift" 'BEGIN { exit !(d > 0.000001) }'; then
        eta_h="$(awk -v g="$gap" -v d="$drift" 'BEGIN { print (-g) / d }')"
      else
        eta_h=""
      fi
    else
      eta_h="0"
    fi

    if [ -z "$eta_h" ]; then
      printf "  %s: %s----%s\n" "$label" "$C_RED" "$C_RESET"
      continue
    fi

    eta_min="$(awk -v h="$eta_h" 'BEGIN { m = int(h * 60.0); if (h * 60.0 > m) m = m + 1; print m }')"
    if [ "$eta_min" -gt "$remain_min" ]; then
      printf "  %s: %sno catch-up before reset%s (need %s)\n" "$label" "$C_RED" "$C_RESET" "$(format_minutes "$eta_min")"
    else
      color=""
      if [ "$eta_min" -ge 480 ]; then
        color="$C_RED"
      elif [ "$eta_min" -ge 60 ]; then
        color="$C_YELLOW"
      else
        color="$C_GREEN"
      fi

      printf "  %s: %s%s%s\n" "$label" "$color" "$(format_minutes "$eta_min")" "$C_RESET"
    fi
  done
}

if [ "$watch_mode" -eq 1 ]; then
  while true; do
    printf '\033[2J\033[H'
    printf 'codex-weekly-pace  (%s)\n\n' "$(date +'%Y-%m-%d %H:%M:%S %z')"
    one_shot || true
    sleep "$interval"
  done
else
  one_shot
fi
