# shellcheck shell=bash
# Serves a NixOS configuration that imports nixosModules.netboot to UEFI PXE
# clients on one network interface:
#
#   firmware PXE --DHCP--> dnsmasq (proxy DHCP, or a full DHCP server)
#                --TFTP--> ipxe.efi (iPXE, embedded script: dhcp, then
#                          chain tftp://<this host>/boot.ipxe)
#                --TFTP--> boot.ipxe (chain http://<this host>:<port>/netboot.ipxe)
#                --HTTP--> netboot.ipxe, bzImage, initrd (darkhttpd)
#
# Proxy DHCP leaves addressing to the network's own DHCP server and only adds
# the boot information, so it is safe on a shared LAN. DHCP mode makes this
# host the DHCP server, for a cable straight to the client.

flake_default=@flake@

usage() {
  cat <<EOF
Usage: netboot NAME [options] [-- NIX-BUILD-ARGS...]

Builds nixosConfigurations.NAME.config.system.build.netboot and serves it.

Options:
  --flake REF              flake with the configuration (default: the flake
                           this app comes from)
  --interface IFACE        interface the client is on (default: the one wired
                           interface with a link and no default route)
  --mode proxy|dhcp        proxy: the network has a DHCP server; dhcp: be the
                           DHCP server (default: dhcp when IFACE has no
                           routable IPv4 address, else proxy)
  --address ADDR           this host's IPv4 address on IFACE (dhcp default:
                           10.42.0.1, added to IFACE while serving)
  --dhcp-range START,END   addresses to hand out in dhcp mode
                           (default: 10.42.0.100,10.42.0.150)
  --http-port PORT         HTTP port for the kernel and initrd (default: 8080)
  --append ARGS            extra kernel command line, e.g. console=ttyS0
  --print-config           print the dnsmasq configuration and exit, without
                           building or serving

Arguments after -- go to nix build, e.g. --builders '...' for a host that
cannot build x86_64-linux itself. Serving needs root (ports 67 and 69); the
app asks sudo for it. The firewall must let in UDP 67, 69 and 4011 and TCP
PORT on IFACE.
EOF
}

die() {
  echo "netboot: $*" >&2
  exit 1
}

os=$(uname -s)

# IPv4 addresses on an interface, one per line.
ipv4_addresses() {
  case "$os" in
  Darwin) ifconfig "$1" 2>/dev/null | awk '$1 == "inet" { print $2 }' ;;
  *) ip -4 -o addr show dev "$1" 2>/dev/null | awk '{ split($4, a, "/"); print a[1] }' ;;
  esac
}

default_route_interface() {
  case "$os" in
  Darwin) route -n get default 2>/dev/null | awk '$1 == "interface:" { print $2 }' ;;
  *) ip route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }' ;;
  esac
}

# Wired interfaces with a link, other than the default route's.
candidate_interfaces() {
  local default iface wifi
  default=$(default_route_interface | sort -u)
  case "$os" in
  Darwin)
    wifi=$(networksetup -listallhardwareports 2>/dev/null |
      awk '/^Hardware Port: Wi-Fi/ { getline; print $2 }')
    for iface in $(ifconfig -l); do
      case "$iface" in en*) ;; *) continue ;; esac
      printf '%s\n%s\n' "$default" "$wifi" | grep -qx "$iface" && continue
      ifconfig "$iface" | grep -q "status: active" || continue
      ifconfig "$iface" | grep -q "media: .*base" || continue
      echo "$iface"
    done
    ;;
  *)
    for iface in /sys/class/net/*; do
      iface=${iface##*/}
      [ "$(cat "/sys/class/net/$iface/type" 2>/dev/null)" = 1 ] || continue
      [ -e "/sys/class/net/$iface/wireless" ] && continue
      readlink -f "/sys/class/net/$iface" | grep -q /virtual/ && continue
      [ "$(cat "/sys/class/net/$iface/carrier" 2>/dev/null)" = 1 ] || continue
      grep -qx "$iface" <<<"$default" && continue
      echo "$iface"
    done
    ;;
  esac
}

name=""
flake=$flake_default
interface=""
mode=""
address=""
dhcp_range=""
http_port=8080
append=""
print_config=false
nix_args=()
serve=""
added_address=false
while [ $# -gt 0 ]; do
  case "$1" in
  --flake) flake="$2" && shift 2 ;;
  --interface) interface="$2" && shift 2 ;;
  --mode) mode="$2" && shift 2 ;;
  --address) address="$2" && shift 2 ;;
  --dhcp-range) dhcp_range="$2" && shift 2 ;;
  --http-port) http_port="$2" && shift 2 ;;
  --append) append="$2" && shift 2 ;;
  --print-config) print_config=true && shift ;;
  # Internal: the root half, given the built tree.
  --serve) serve="$2" && shift 2 ;;
  -h | --help) usage && exit 0 ;;
  --)
    shift
    nix_args=("$@")
    break
    ;;
  -*) usage >&2 && exit 64 ;;
  *)
    [ -z "$name" ] || { usage >&2 && exit 64; }
    name="$1"
    shift
    ;;
  esac
done

if [ -z "$serve" ]; then
  [ -n "$name" ] || { usage >&2 && exit 64; }

  if [ -z "$interface" ]; then
    mapfile -t candidates < <(candidate_interfaces)
    case "${#candidates[@]}" in
    1) interface=${candidates[0]} ;;
    0) die "no wired interface with a link other than the default route's; pass --interface" ;;
    *) die "several candidate interfaces (${candidates[*]}); pass --interface" ;;
    esac
    echo "netboot: using interface $interface" >&2
  fi

  if [ -z "$mode" ]; then
    mode=dhcp
    while read -r a; do
      case "$a" in "" | 169.254.* | "${address:-10.42.0.1}") ;; *) mode=proxy ;; esac
    done < <(ipv4_addresses "$interface")
    echo "netboot: using $mode mode" >&2
  fi
  case "$mode" in proxy | dhcp) ;; *) die "--mode is proxy or dhcp" ;; esac

  if [ "$mode" = dhcp ]; then
    address=${address:-10.42.0.1}
    dhcp_range=${dhcp_range:-10.42.0.100,10.42.0.150}
  elif [ -z "$address" ]; then
    address=$(ipv4_addresses "$interface" | grep -v '^169\.254\.' | head -n1 || true)
    [ -n "$address" ] || die "$interface has no IPv4 address; pass --address or --mode dhcp"
  fi

  if ! $print_config; then
    echo "netboot: building $flake#nixosConfigurations.$name.config.system.build.netboot" >&2
    tree=$(nix build --no-link --print-out-paths \
      "$flake#nixosConfigurations.\"$name\".config.system.build.netboot" "${nix_args[@]}")
  else
    tree=/nonexistent
  fi

  args=(--serve "$tree" --interface "$interface" --mode "$mode" --address "$address"
    --http-port "$http_port" --append "$append")
  [ "$mode" = dhcp ] && args+=(--dhcp-range "$dhcp_range")
  $print_config && args+=(--print-config)
  if $print_config || [ "$(id -u)" = 0 ]; then
    exec "$0" "${args[@]}"
  fi
  exec sudo "$0" "${args[@]}"
fi

# Root half: $serve is the built tree.
state=$(mktemp -d "${TMPDIR:-/tmp}/netboot.XXXXXX")
cleanup() {
  local pid
  for pid in $(jobs -p); do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$state"
  if $added_address; then
    case "$os" in
    Darwin) ifconfig "$interface" inet "$address" -alias 2>/dev/null || true ;;
    *) ip addr del "$address/24" dev "$interface" 2>/dev/null || true ;;
    esac
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

{
  echo "port=0"
  echo "pid-file="
  echo "dhcp-leasefile=$state/dnsmasq.leases"
  echo "interface=$interface"
  echo "log-dhcp"
  echo "enable-tftp"
  echo "tftp-root=$state/tftp"
  # Option 93, client system architecture: 7 and 9 are x86-64 UEFI.
  echo "dhcp-match=set:efi-x86_64,option:client-arch,7"
  echo "dhcp-match=set:efi-x86_64,option:client-arch,9"
  if [ "$mode" = dhcp ]; then
    echo "dhcp-range=$dhcp_range,12h"
    echo "dhcp-boot=tag:efi-x86_64,ipxe.efi"
    echo "dhcp-authoritative"
  else
    echo "dhcp-range=$address,proxy"
    echo "pxe-prompt=netboot,0"
    echo "pxe-service=tag:efi-x86_64,x86-64_EFI,netboot,ipxe.efi"
  fi
} >"$state/dnsmasq.conf"

if $print_config; then
  cat "$state/dnsmasq.conf"
  exit 0
fi

[ -f "$serve/ipxe.efi" ] || die "$serve has no ipxe.efi: does the configuration import nixosModules.netboot?"

if ! ipv4_addresses "$interface" | grep -qx "$address"; then
  case "$os" in
  Darwin) ifconfig "$interface" inet "$address" netmask 255.255.255.0 alias ;;
  *) ip addr add "$address/24" dev "$interface" ;;
  esac
  added_address=true
fi

mkdir "$state/tftp"
cp "$serve/ipxe.efi" "$state/tftp/ipxe.efi"
# netboot.ipxe appends ${cmdline} to the kernel command line.
cat >"$state/tftp/boot.ipxe" <<EOF
#!ipxe
set cmdline $append
chain http://$address:$http_port/netboot.ipxe
EOF
# dnsmasq drops root before serving TFTP.
chmod -R a+rX "$state"

echo "netboot: serving $serve on $interface ($address, $mode mode), HTTP port $http_port" >&2
darkhttpd "$serve" --addr "$address" --port "$http_port" --no-listing &
dnsmasq --keep-in-foreground --log-facility=- --conf-file="$state/dnsmasq.conf" &
wait -n
