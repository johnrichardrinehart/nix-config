#!/usr/bin/env bash
set -uo pipefail

SYSFS_ROOT=${DISPLAY_LINK_SYSFS_ROOT:-/sys}
PROCFS_ROOT=${DISPLAY_LINK_PROCFS_ROOT:-/proc}
DEV_ROOT=${DISPLAY_LINK_DEV_ROOT:-/dev}
LOG_ROOT=${DISPLAY_LINK_LOG_ROOT:-/var/log/display-link-debug}
RUN_ROOT=${DISPLAY_LINK_RUN_ROOT:-/run/display-link-debug}
TRACE_ROOT=${DISPLAY_LINK_TRACE_ROOT:-$SYSFS_ROOT/kernel/tracing}
TEST_MODE=${DISPLAY_LINK_TEST_MODE:-0}

log() { printf 'display-link-debug: %s\n' "$*" >&2; }
need_root() {
  if [[ ${EUID} -ne 0 && $TEST_MODE != 1 ]]; then
    log "this command must run as root (try sudo)"
    exit 1
  fi
}

connector_state() {
  local connector status enabled modes edid_bytes
  for connector in "$SYSFS_ROOT"/class/drm/card*-*/; do
    [[ -e ${connector}status ]] || continue
    status=$(<"${connector}status")
    enabled="unknown"
    modes=0
    edid_bytes=0
    [[ -r ${connector}enabled ]] && enabled=$(<"${connector}enabled")
    [[ -r ${connector}modes ]] && modes=$(wc -l <"${connector}modes")
    [[ -r ${connector}edid ]] && edid_bytes=$(wc -c <"${connector}edid")
    printf '%s status=%s enabled=%s modes=%s edid_bytes=%s\n' \
      "$(basename "${connector%/}")" "$status" "$enabled" "$modes" "$edid_bytes"
  done
}

pci_power_state() {
  local device driver class control runtime d3cold
  for device in "$SYSFS_ROOT"/bus/pci/devices/*; do
    [[ -e ${device} ]] || continue
    driver="none"
    [[ -L ${device}/driver ]] && driver=$(basename "$(readlink -f "${device}/driver")")
    class=$(<"${device}/class")
    case "${driver}:${class}" in
    thunderbolt:* | xhci_hcd:* | i915:* | pcieport:0x0604*) ;;
    *) continue ;;
    esac
    control="n/a"
    runtime="n/a"
    d3cold="n/a"
    [[ -r ${device}/power/control ]] && control=$(<"${device}/power/control")
    [[ -r ${device}/power/runtime_status ]] && runtime=$(<"${device}/power/runtime_status")
    [[ -r ${device}/d3cold_allowed ]] && d3cold=$(<"${device}/d3cold_allowed")
    printf '%s driver=%s class=%s control=%s runtime=%s d3cold_allowed=%s\n' \
      "$(basename "$device")" "$driver" "$class" "$control" "$runtime" "$d3cold"
  done
}

state() {
  echo '=== DRM connectors ==='
  connector_state
  echo '=== Thunderbolt/USB4 devices ==='
  local device value
  for device in "$SYSFS_ROOT"/bus/thunderbolt/devices/*; do
    [[ -e ${device} ]] || continue
    printf '%s' "$(basename "$device")"
    for value in device_name vendor_name authorized generation rx_speed tx_speed; do
      [[ -r ${device}/${value} ]] && printf ' %s=%q' "$value" "$(<"${device}/${value}")"
    done
    echo
  done
  echo '=== PCI power ==='
  pci_power_state
}

snapshot() {
  need_root
  local label=${1:-manual} stamp destination file parameter
  stamp=$(date --utc +%Y%m%dT%H%M%SZ)
  label=${label//[^A-Za-z0-9_.-]/_}
  destination="$LOG_ROOT/${stamp}-${label}"
  install -d -m 0700 "$destination"
  log "collecting snapshot in $destination"

  {
    date --iso-8601=ns
    uname -a
    printf 'cmdline: '
    cat "$PROCFS_ROOT/cmdline"
    state
  } >"$destination/summary.txt" 2>&1
  lspci -nnvv >"$destination/lspci-nnvv.txt" 2>&1 || true
  lsusb -tv >"$destination/lsusb-tree.txt" 2>&1 || true
  boltctl list -a >"$destination/boltctl.txt" 2>&1 || true
  {
    ddcutil detect --verbose || true
    for file in "$DEV_ROOT"/i2c-*; do
      [[ -e $file ]] || continue
      printf '\n=== monitor power state on %s ===\n' "$file"
      ddcutil --bus "${file##*-}" getvcp D6 --brief || true
    done
  } >"$destination/ddc-monitor-power.txt" 2>&1
  journalctl -b -k -o short-monotonic --no-pager >"$destination/kernel-journal.txt" 2>&1 || true
  journalctl -b -u systemd-suspend.service -u systemd-hibernate.service \
    -u external-display-recovery.service -o short-monotonic --no-pager \
    >"$destination/sleep-recovery-journal.txt" 2>&1 || true

  install -d "$destination/drm" "$destination/thunderbolt" "$destination/modules"
  for file in "$SYSFS_ROOT"/class/drm/card*-*/{status,enabled,modes,dpms}; do
    [[ -r $file ]] || continue
    cp "$file" "$destination/drm/$(basename "$(dirname "$file")")-$(basename "$file")" || true
  done
  for file in "$SYSFS_ROOT"/class/drm/card*-*/edid; do
    [[ -r $file ]] || continue
    edid-decode "$file" >"$destination/drm/$(basename "$(dirname "$file")")-edid.txt" 2>&1 || true
  done
  find -L "$SYSFS_ROOT/bus/thunderbolt/devices" -maxdepth 2 -type f -readable -print0 2>/dev/null |
    while IFS= read -r -d '' file; do
      printf '\n=== %s ===\n' "${file#"$SYSFS_ROOT/bus/thunderbolt/devices/"}"
      cat "$file" 2>/dev/null || true
    done >"$destination/thunderbolt/sysfs.txt"
  for parameter in "$SYSFS_ROOT"/module/{thunderbolt,i915,xe,xhci_pci}/parameters/*; do
    [[ -r $parameter ]] || continue
    printf '%s\n' "$(<"$parameter")" >"$destination/modules/$(basename "$(dirname "$(dirname "$parameter")")")-$(basename "$parameter")" 2>/dev/null || true
  done
  for file in "$SYSFS_ROOT"/kernel/debug/dri/*/{i915_display_info,i915_runtime_pm_status}; do
    [[ -r $file ]] || continue
    cp "$file" "$destination/drm/$(basename "$(dirname "$file")")-$(basename "$file")" || true
  done

  log "snapshot complete: $destination"
  printf '%s\n' "$destination"
}

dynamic_debug() {
  need_root
  local mode=${1:-} flag query control="$PROCFS_ROOT/dynamic_debug/control"
  [[ -w $control ]] || {
    log "$control is unavailable; kernel needs CONFIG_DYNAMIC_DEBUG"
    exit 1
  }
  case "$mode" in
  on) flag='+p' ;;
  off) flag='-p' ;;
  *)
    log 'usage: display-link-debug dynamic-debug on|off'
    exit 2
    ;;
  esac
  for query in \
    'module thunderbolt' \
    'module i915' \
    'file drivers/gpu/drm/display/drm_dp_mst_topology.c' \
    'file drivers/gpu/drm/display/drm_dp_helper.c' \
    'file drivers/pci/pci.c' \
    'file drivers/pci/pcie/aspm.c' \
    'file drivers/pci/hotplug/pciehp*' \
    'file drivers/usb/typec/*' \
    'file drivers/usb/host/xhci*'; do
    printf '%s %s\n' "$query" "$flag" >"$control" 2>/dev/null || true
  done
  log "dynamic debug ${mode}"
}

trace_toggle() {
  need_root
  local mode=${1:-} value group event_root="$TRACE_ROOT/events"
  case "$mode" in on) value=1 ;; off) value=0 ;; *)
    log 'usage: display-link-debug trace on|off'
    exit 2
    ;;
  esac
  if [[ $TEST_MODE != 1 ]]; then
    mountpoint -q "$TRACE_ROOT" || mount -t tracefs tracefs "$TRACE_ROOT"
  fi
  for group in thunderbolt drm intel_display i915 typec; do
    [[ -w ${event_root}/${group}/enable ]] && printf '%s\n' "$value" >"${event_root}/${group}/enable"
  done
  log "display-link tracepoints ${mode}; read /sys/kernel/tracing/trace"
}

healthy_external_connector() {
  local connector=$1 name
  name=$(basename "${connector%/}")
  [[ $name != *-eDP-* ]] || return 1
  [[ -r ${connector}status && $(<"${connector}status") == connected ]] || return 1
  [[ -s ${connector}modes && -s ${connector}edid ]]
}

healthy_external_connector_count() {
  local connector count=0
  for connector in "$SYSFS_ROOT"/class/drm/card*-*/; do
    [[ -e $connector ]] || continue
    healthy_external_connector "$connector" && ((count += 1))
  done
  printf '%s\n' "$count"
}

notify_display_consumers() {
  local connector name card
  declare -A cards=()

  for connector in "$SYSFS_ROOT"/class/drm/card*-*/; do
    [[ -e $connector ]] || continue
    healthy_external_connector "$connector" || continue
    name=$(basename "${connector%/}")
    card="$SYSFS_ROOT/class/drm/${name%%-*}"
    [[ -w ${card}/uevent ]] && cards["$card"]=1
  done

  # Notify the DRM device rather than its connector kobject. Compositors watch
  # the card device number and rescan all connectors when that device changes.
  for card in "${!cards[@]}"; do
    printf 'change\n' >"${card}/uevent"
  done
  udevadm settle --timeout=5 || true
}

thunderbolt_controller_for_domain() {
  local domain=$1 path controller
  path=$(readlink -f "$domain") || return 1
  controller=$(basename "$(dirname "$path")")
  [[ $controller =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[[:xdigit:]]$ ]] || return 1
  printf '%s\n' "$controller"
}

reprobe_thunderbolt_controller() {
  local controller=$1 driver="$SYSFS_ROOT/bus/pci/drivers/thunderbolt"
  local device="$SYSFS_ROOT/bus/pci/devices/$controller" control='' d3cold=''
  [[ -e $device || $TEST_MODE == 1 ]] || {
    log "Thunderbolt controller $controller disappeared before re-probe"
    return 1
  }
  if [[ $TEST_MODE != 1 ]]; then
    [[ -L $device/driver && $(basename "$(readlink -f "$device/driver")") == thunderbolt ]] || {
      log "$controller is not bound to the Thunderbolt driver"
      return 1
    }
  fi
  [[ -w $driver/unbind && -w $driver/bind ]] || {
    log "Thunderbolt driver bind controls are unavailable"
    return 1
  }
  [[ -r $device/power/control ]] && control=$(<"$device/power/control")
  [[ -r $device/d3cold_allowed ]] && d3cold=$(<"$device/d3cold_allowed")

  log "re-probing unresponsive Thunderbolt controller $controller"
  printf '%s\n' "$controller" >"$driver/unbind" || return 1
  udevadm settle --timeout=5 || true
  printf '%s\n' "$controller" >"$driver/bind" || return 1
  udevadm settle --timeout=10 || true

  [[ -n $control && -w $device/power/control ]] && printf '%s\n' "$control" >"$device/power/control"
  [[ -n $d3cold && -w $device/d3cold_allowed ]] && printf '%s\n' "$d3cold" >"$device/d3cold_allowed"
}

quiesce_usb_ports() {
  need_root
  local port state disabled state_file="$RUN_ROOT/quiesced-usb-ports"
  install -d -m 0700 "$RUN_ROOT"
  : >"$state_file.tmp"

  for port in "$SYSFS_ROOT"/bus/usb/devices/usb*/*-0:1.0/usb*-port*; do
    [[ -r $port/state && -w $port/disable ]] || continue
    state=$(<"$port/state")
    disabled=$(<"$port/disable")
    [[ $state == default && $disabled == 0 ]] || continue

    log "quiescing USB root-hub port ${port#"$SYSFS_ROOT"/} stuck in enumeration"
    if printf '1\n' >"$port/disable"; then
      printf '%s\n' "$port" >>"$state_file.tmp"
    fi
  done

  mv "$state_file.tmp" "$state_file"
}

restore_usb_ports() {
  need_root
  local port state_file="$RUN_ROOT/quiesced-usb-ports"
  [[ -r $state_file ]] || return 0

  while IFS= read -r port; do
    [[ $port == "$SYSFS_ROOT"/* && -w $port/disable ]] || continue
    log "restoring USB root-hub port ${port#"$SYSFS_ROOT"/}"
    printf '0\n' >"$port/disable" || true
  done <"$state_file"
  rm -f "$state_file"
}

repair() {
  need_root
  local attempts=${1:-6} delay=${2:-2} minimum=${3:-1} hard_recovery=${4:-}
  local attempt domain domain_root controller healthy
  declare -A failed_controllers=()

  healthy=$(healthy_external_connector_count)
  if ((healthy >= minimum)); then
    log "${healthy} healthy external DRM connector(s) are present"
    return 0
  fi

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    log "recovery attempt ${attempt}/${attempts}"

    # A downstream MST connector can become usable after the event that starts
    # this service. Let the topology settle before tearing it down with a rescan.
    sleep "$delay"
    healthy=$(healthy_external_connector_count)
    if ((healthy >= minimum)); then
      notify_display_consumers
      log "${healthy} healthy external DRM connector(s) appeared"
      return 0
    fi

    failed_controllers=()
    for domain in "$SYSFS_ROOT"/bus/thunderbolt/devices/domain*/rescan; do
      [[ -w $domain ]] || continue
      if ! printf '1\n' >"$domain"; then
        domain_root=$(dirname "$domain")
        if controller=$(thunderbolt_controller_for_domain "$domain_root"); then
          failed_controllers["$controller"]=1
        fi
      fi
    done
    udevadm settle --timeout=5 || true

    if [[ $hard_recovery == reprobe && ${#failed_controllers[@]} -gt 0 ]]; then
      for controller in "${!failed_controllers[@]}"; do
        reprobe_thunderbolt_controller "$controller" || true
      done
      # Re-probe only once. A second failure needs a preserved diagnostic state.
      hard_recovery=reprobed
      sleep "$delay"
    fi

    healthy=$(healthy_external_connector_count)
    if ((healthy >= minimum)); then
      notify_display_consumers
      log "${healthy} healthy external DRM connector(s) appeared"
      return 0
    fi
  done
  log "fewer than ${minimum} healthy external DRM connector(s) appeared; preserving the failed state for diagnosis"
  return 1
}

diagnose() {
  local tb=0 external=0 device
  for device in "$SYSFS_ROOT"/bus/thunderbolt/devices/[0-9]*-[1-9]*; do
    [[ -e $device ]] && tb=1
  done
  while IFS= read -r line; do
    [[ $line != *-eDP-*status=connected* && $line == *status=connected* ]] && external=1
  done < <(connector_state)
  state
  echo '=== Assessment ==='
  if ((external == 1)); then
    echo 'Kernel DRM sees an external connector. If the panel has no image, inspect compositor state, link-training messages, and the EDID in a snapshot.'
  elif ((tb == 1)); then
    echo 'Thunderbolt/USB4 enumerated but DRM did not expose an external connector: suspect DP tunnel allocation, DP AUX/MST discovery, or monitor DP wake behavior.'
  else
    echo 'Neither a downstream Thunderbolt device nor external DRM connector is present: suspect cable/monitor wake, USB-C/Thunderbolt negotiation, authorization, or host-controller power state.'
  fi
}

usage() {
  cat <<'EOF'
Usage: display-link-debug COMMAND [ARGS]

Commands:
  state                       Print DRM, Thunderbolt, and PCI power state
  diagnose                    Print state plus a first-pass fault classification
  snapshot [LABEL]            Save a root-only diagnostic bundle under /var/log
  dynamic-debug on|off        Toggle relevant kernel dynamic-debug callsites
  trace on|off                Toggle available display-link tracepoint groups
  repair [TRIES] [DELAY] [N] [reprobe]
                              Retry rescans; optionally re-probe an NHI whose ICM transport failed
  quiesce-usb-ports          Disable root-hub ports stuck in device enumeration before sleep
  restore-usb-ports          Restore root-hub ports disabled before sleep
EOF
}

case "${1:-}" in
state) state ;;
diagnose) diagnose ;;
snapshot) snapshot "${2:-manual}" ;;
dynamic-debug) dynamic_debug "${2:-}" ;;
trace) trace_toggle "${2:-}" ;;
repair) repair "${2:-6}" "${3:-2}" "${4:-1}" "${5:-}" ;;
quiesce-usb-ports) quiesce_usb_ports ;;
restore-usb-ports) restore_usb_ports ;;
*)
  usage
  [[ $# -eq 0 ]] || exit 2
  ;;
esac
