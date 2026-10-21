# shellcheck shell=bash
# Serves @name@ to UEFI PXE clients on one network interface:
#
#   firmware PXE --DHCP--> dnsmasq (proxy DHCP, or a full DHCP server)
#                --TFTP--> ipxe.efi (iPXE, embedded script: dhcp, then
#                          chain tftp://<this host>/boot.ipxe)
#                --TFTP--> boot.ipxe (chain http://<this host>:<port>/netboot.ipxe)
#                --HTTP--> netboot.ipxe, bzImage, initrd (darkhttpd)
#
# Proxy DHCP (the default) leaves addressing to the network's DHCP server and
# only adds the boot information, so it is safe on a shared LAN. --dhcp-range
# makes this host the DHCP server instead, for a cable straight to the client
# on an interface that already has a static address.

tree=@tree@
ipxe_efi=@ipxeEfi@

usage() {
  cat <<EOF
Usage: $(basename "$0") --interface IFACE [options]

Options:
  --interface IFACE        interface the client is reachable on (required)
  --address ADDR           this host's IPv4 address on IFACE (default: detected)
  --dhcp-range START,END   act as the DHCP server for this range instead of
                           proxy DHCP
  --http-port PORT         HTTP port for the kernel and initrd (default: 8080)
  --append ARGS            extra kernel command line, e.g. console=ttyS0
  --print-config           print the dnsmasq configuration and exit

Needs root: DHCP and TFTP listen on ports 67 and 69.
EOF
}

interface=""
address=""
dhcp_range=""
http_port=8080
append=""
print_config=false
while [ $# -gt 0 ]; do
  case "$1" in
  --interface)
    interface="$2"
    shift 2
    ;;
  --address)
    address="$2"
    shift 2
    ;;
  --dhcp-range)
    dhcp_range="$2"
    shift 2
    ;;
  --http-port)
    http_port="$2"
    shift 2
    ;;
  --append)
    append="$2"
    shift 2
    ;;
  --print-config)
    print_config=true
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 64
    ;;
  esac
done

if [ -z "$interface" ]; then
  usage >&2
  exit 64
fi

if [ -z "$address" ]; then
  case "$(uname -s)" in
  Darwin) address=$(ipconfig getifaddr "$interface" || true) ;;
  *) address=$(ip -4 -o addr show dev "$interface" | awk '{ split($4, a, "/"); print a[1]; exit }') ;;
  esac
fi
if [ -z "$address" ]; then
  echo "$interface has no IPv4 address; pass --address" >&2
  exit 1
fi

state=$(mktemp -d "${TMPDIR:-/tmp}/netboot-server.XXXXXX")
cleanup() {
  local pid
  for pid in $(jobs -p); do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$state"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir "$state/tftp"
cp "$ipxe_efi" "$state/tftp/ipxe.efi"
# netboot.ipxe appends ${cmdline} to the kernel command line.
cat >"$state/tftp/boot.ipxe" <<EOF
#!ipxe
set cmdline $append
chain http://$address:$http_port/netboot.ipxe
EOF
# dnsmasq drops root before serving TFTP.
chmod -R a+rX "$state"

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
  if [ -n "$dhcp_range" ]; then
    echo "dhcp-range=$dhcp_range,12h"
    echo "dhcp-boot=tag:efi-x86_64,ipxe.efi"
    echo "dhcp-authoritative"
  else
    echo "dhcp-range=$address,proxy"
    echo "pxe-prompt=@name@,0"
    echo "pxe-service=tag:efi-x86_64,x86-64_EFI,@name@,ipxe.efi"
  fi
} >"$state/dnsmasq.conf"

if $print_config; then
  cat "$state/dnsmasq.conf"
  exit 0
fi

echo "Serving $tree on $interface ($address): HTTP port $http_port" >&2

darkhttpd "$tree" --addr "$address" --port "$http_port" --no-listing &
dnsmasq --keep-in-foreground --log-facility=- --conf-file="$state/dnsmasq.conf" &
wait -n
