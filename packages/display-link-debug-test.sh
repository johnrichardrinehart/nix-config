#!/usr/bin/env bash
set -euo pipefail

program=${DISPLAY_LINK_PROGRAM:?DISPLAY_LINK_PROGRAM must name the packaged executable}
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
sys="$root/sys"
proc="$root/proc"
dev="$root/dev"
logs="$root/logs"
mkdir -p "$sys/class/drm/card0" "$sys/bus/pci/devices" "$sys/bus/thunderbolt/devices" \
  "$sys/module" "$sys/kernel/debug/dri" "$proc/dynamic_debug" "$dev" "$logs"
printf 'none\n' >"$sys/class/drm/card0/uevent"
printf 'test-kernel-arguments\n' >"$proc/cmdline"
printf '\n' >"$proc/dynamic_debug/control"

run() {
  DISPLAY_LINK_TEST_MODE=1 \
    DISPLAY_LINK_SYSFS_ROOT="$sys" \
    DISPLAY_LINK_PROCFS_ROOT="$proc" \
    DISPLAY_LINK_DEV_ROOT="$dev" \
    DISPLAY_LINK_LOG_ROOT="$logs" \
    DISPLAY_LINK_RUN_ROOT="$root/run" \
    DISPLAY_LINK_TRACE_ROOT="$sys/kernel/tracing" \
    "$program" "$@"
}

connector() {
  local name=$1 status=$2 enabled=${3:-disabled}
  mkdir -p "$sys/class/drm/$name"
  printf '%s\n' "$status" >"$sys/class/drm/$name/status"
  printf '%s\n' "$enabled" >"$sys/class/drm/$name/enabled"
  : >"$sys/class/drm/$name/modes"
  : >"$sys/class/drm/$name/edid"
}

make_healthy() {
  local name=$1
  printf '2560x1440\n' >"$sys/class/drm/$name/modes"
  printf 'mock-edid\n' >"$sys/class/drm/$name/edid"
}

assert_contains() {
  [[ $1 == *"$2"* ]] || {
    printf 'expected output to contain %q, got:\n%s\n' "$2" "$1" >&2
    exit 1
  }
}

connector card0-eDP-1 connected enabled
connector card0-DP-1 disconnected
output=$(run state)
assert_contains "$output" 'card0-eDP-1 status=connected enabled=enabled'
assert_contains "$output" 'card0-DP-1 status=disconnected'

output=$(run diagnose)
assert_contains "$output" 'Neither a downstream Thunderbolt device nor external DRM connector is present'

mkdir -p "$sys/bus/thunderbolt/devices/0-1"
output=$(run diagnose)
assert_contains "$output" 'Thunderbolt/USB4 enumerated but DRM did not expose an external connector'

printf 'connected\n' >"$sys/class/drm/card0-DP-1/status"
connector card0-DP-2 connected enabled
output=$(run diagnose)
assert_contains "$output" 'Kernel DRM sees an external connector'

mkdir -p "$sys/bus/thunderbolt/devices/domain0"
printf '0\n' >"$sys/bus/thunderbolt/devices/domain0/rescan"
if run repair 1 0 2; then
  echo 'repair accepted connected connectors without modes or EDIDs' >&2
  exit 1
fi
[[ $(<"$sys/bus/thunderbolt/devices/domain0/rescan") == 1 ]]

printf '0\n' >"$sys/bus/thunderbolt/devices/domain0/rescan"
(
  sleep 0.1
  make_healthy card0-DP-1
  make_healthy card0-DP-2
) &
run repair 1 1 2
[[ $(<"$sys/bus/thunderbolt/devices/domain0/rescan") == 0 ]]
[[ $(<"$sys/class/drm/card0-DP-1/status") == connected ]]
[[ $(<"$sys/class/drm/card0-DP-2/status") == connected ]]
[[ $(<"$sys/class/drm/card0/uevent") == change ]]

printf 'none\n' >"$sys/class/drm/card0/uevent"
printf '0\n' >"$sys/bus/thunderbolt/devices/domain0/rescan"
run repair 1 0 2
[[ $(<"$sys/bus/thunderbolt/devices/domain0/rescan") == 0 ]]
[[ $(<"$sys/class/drm/card0/uevent") == none ]]

printf 'disconnected\n' >"$sys/class/drm/card0-DP-2/status"
if run repair 1 0 2; then
  echo 'repair unexpectedly succeeded with fewer than two healthy external connectors' >&2
  exit 1
fi

# A failed ICM rescan identifies its parent NHI and re-probes only that
# Thunderbolt PCI function when hard recovery is enabled.
mkdir -p "$sys/devices/pci0000:00/0000:00:0d.3/domain1"
rm -rf "$sys/bus/thunderbolt/devices/domain0"
ln -s ../../../devices/pci0000:00/0000:00:0d.3/domain1 \
  "$sys/bus/thunderbolt/devices/domain1"
ln -s /dev/full "$sys/devices/pci0000:00/0000:00:0d.3/domain1/rescan"
mkdir -p "$sys/bus/pci/drivers/thunderbolt"
: >"$sys/bus/pci/drivers/thunderbolt/unbind"
: >"$sys/bus/pci/drivers/thunderbolt/bind"
if run repair 1 0 2 reprobe; then
  echo 'repair unexpectedly succeeded after a mocked failed re-probe' >&2
  exit 1
fi
[[ $(<"$sys/bus/pci/drivers/thunderbolt/unbind") == 0000:00:0d.3 ]]
[[ $(<"$sys/bus/pci/drivers/thunderbolt/bind") == 0000:00:0d.3 ]]

# Quiesce only root-hub ports stuck in USB enumeration. Restore the same ports
# after the sleep transaction completes.
mkdir -p "$sys/bus/usb/devices/usb3/3-0:1.0/usb3-port2"
mkdir -p "$sys/bus/usb/devices/usb3/3-0:1.0/usb3-port3"
printf 'not attached\n' >"$sys/bus/usb/devices/usb3/3-0:1.0/usb3-port2/state"
printf '0\n' >"$sys/bus/usb/devices/usb3/3-0:1.0/usb3-port2/disable"
printf 'default\n' >"$sys/bus/usb/devices/usb3/3-0:1.0/usb3-port3/state"
printf '0\n' >"$sys/bus/usb/devices/usb3/3-0:1.0/usb3-port3/disable"
run quiesce-usb-ports
[[ $(<"$sys/bus/usb/devices/usb3/3-0:1.0/usb3-port2/disable") == 0 ]]
[[ $(<"$sys/bus/usb/devices/usb3/3-0:1.0/usb3-port3/disable") == 1 ]]
run restore-usb-ports
[[ $(<"$sys/bus/usb/devices/usb3/3-0:1.0/usb3-port3/disable") == 0 ]]

snapshot=$(run snapshot 'label with spaces')
[[ $snapshot == "$logs/"*'-label_with_spaces' ]]
[[ -s $snapshot/summary.txt ]]
[[ -f $snapshot/kernel-journal.txt ]]
assert_contains "$(<"$snapshot/summary.txt")" 'test-kernel-arguments'

run dynamic-debug on
assert_contains "$(<"$proc/dynamic_debug/control")" '+p'
run dynamic-debug off
assert_contains "$(<"$proc/dynamic_debug/control")" '-p'

for group in thunderbolt drm intel_display i915 typec; do
  mkdir -p "$sys/kernel/tracing/events/$group"
  printf '0\n' >"$sys/kernel/tracing/events/$group/enable"
done
run trace on
[[ $(<"$sys/kernel/tracing/events/drm/enable") == 1 ]]
run trace off
[[ $(<"$sys/kernel/tracing/events/drm/enable") == 0 ]]

if run dynamic-debug invalid; then
  echo 'dynamic-debug unexpectedly accepted an invalid mode' >&2
  exit 1
fi
if run trace invalid; then
  echo 'trace unexpectedly accepted an invalid mode' >&2
  exit 1
fi
if run unknown-command; then
  echo 'unknown command unexpectedly succeeded' >&2
  exit 1
fi

printf 'display-link-debug tests passed\n'
