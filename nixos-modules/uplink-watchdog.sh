# shellcheck shell=bash
# Demote IPv4 default routes whose uplink cannot reach the internet.
#
# Every UPLINK_INTERVAL seconds, ping UPLINK_TARGETS through each interface that
# carries a DHCP default route in the main table. After UPLINK_FAILS failed
# rounds, the route is re-added with its metric raised by UPLINK_PENALTY and,
# when UPLINK_RESOLVED=1, the link stops being a DNS default route in
# systemd-resolved. One good round reverses both. Demoted routes carry protocol
# UPLINK_PROTO, so they never collide with the dhcpcd/iwd originals (protocol
# dhcp). Those daemons re-add their route on lease renewal; the next round
# demotes it again.

interval=${UPLINK_INTERVAL:-10}
fails_needed=${UPLINK_FAILS:-2}
penalty=${UPLINK_PENALTY:-20000}
proto=${UPLINK_PROTO:-77}
resolved=${UPLINK_RESOLVED:-0}
read -r -a targets <<<"${UPLINK_TARGETS:-1.1.1.1 9.9.9.9}"

declare -A fails=() demoted=()

# Interfaces with a default route installed by DHCP or demoted by us.
devs() {
  {
    ip -4 -j route show table main default proto dhcp
    ip -4 -j route show table main default proto "$proto"
  } | jq -r '.[].dev' | sort -u
}

# Default routes on interface $1 with protocol $2, one "metric hop..." line
# each. `ip` omits the dev and protocol fields because they are filters.
routes() {
  ip -4 -j route show table main default proto "$2" dev "$1" |
    jq -r '.[] | [.metric // 0,
      (if .gateway then "via", .gateway else empty end),
      (if .prefsrc then "src", .prefsrc else empty end),
      (if (.flags // []) | index("onlink") then "onlink" else empty end)] | join(" ")'
}

dns_default_route() {
  [[ $resolved == 1 ]] && resolvectl default-route "$1" "$2"
}

probe() {
  local target
  for target in "${targets[@]}"; do
    ping -n -q -c1 -W2 -I "$1" "$target" >/dev/null 2>&1 && return 0
  done
  return 1
}

demote() {
  local dev=$1 metric hop
  while read -r metric hop; do
    # shellcheck disable=SC2086 # hop is a word list built by routes()
    ip route replace default $hop dev "$dev" proto "$proto" metric $((metric + penalty)) &&
      ip route del default $hop dev "$dev" proto dhcp metric "$metric"
  done < <(routes "$dev" dhcp)
  # Re-asserted every round: iwd and dhcpcd may reset link DNS on renewal.
  dns_default_route "$dev" false
  if [[ -z ${demoted[$dev]:-} ]]; then
    demoted[$dev]=1
    echo "$dev: no reply from ${targets[*]}; demoted default route by $penalty"
  fi
}

# Undo demote() on interface $1; $2 says why, for the log.
restore() {
  local dev=$1 reason=$2 metric hop found=
  while read -r metric hop; do
    found=1
    # shellcheck disable=SC2086 # hop is a word list built by routes()
    ip route replace default $hop dev "$dev" proto dhcp metric $((metric - penalty)) &&
      ip route del default $hop dev "$dev" proto "$proto" metric "$metric"
  done < <(routes "$dev" "$proto")
  if [[ -n $found || -n ${demoted[$dev]:-} ]]; then
    unset 'demoted[$dev]'
    dns_default_route "$dev" true
    echo "$dev: $reason; restored default route"
  fi
}

restore_all() {
  local dev
  for dev in $(devs); do restore "$dev" "watchdog stopping"; done
  exit 0
}
trap restore_all TERM INT

while :; do
  for dev in $(devs); do
    if probe "$dev"; then
      fails[$dev]=0
      restore "$dev" "reachable again"
    else
      fails[$dev]=$((${fails[$dev]:-0} + 1))
      if ((fails[$dev] >= fails_needed)); then demote "$dev"; fi
    fi
  done
  sleep "$interval" &
  wait $!
done
