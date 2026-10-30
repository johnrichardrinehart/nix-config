# Share every network the machine is on over Wi-Fi: the wired uplink,
# Tailscale (tailnet and accepted subnet routes), Nebula, and whatever
# interface appears later. iwd runs the access point (Wi-Fi 5, VHT 80 MHz on
# 5 GHz with the patches/iwd/ series of network.nix) and its DHCP server,
# systemd-resolved answers DNS, and the NAT below does the rest.
#
# The access point is not started at boot. As root:
#
#   iwctl device <interface> set-property Mode ap
#   iwctl ap <interface> start-profile <ssid>
#
# and back with `iwctl ap <interface> stop` and `... set-property Mode
# station`. impala (network.nix) does the same, and shares the running access
# point as a Wi-Fi QR code with ctrl+q.
#
# The passphrase is the `wifi-ap-passphrase` key of `sopsFile`; sops-nix
# decrypts it at activation and renders the profile (iwd.ap(5)) into iwd's
# state directory, root-only.
{ config, lib, ... }:
let
  cfg = config.dev.johnrinehart.wifiAccessPoint;
  inherit (lib) mkOption types;

  # The access point's /24.
  network = lib.concatStringsSep "." (lib.take 3 (lib.splitString "." cfg.address));
  subnet = "${network}.0/24";
in
{
  options.dev.johnrinehart.wifiAccessPoint = {
    enable = lib.mkEnableOption "an iwd Wi-Fi access point that shares every network the machine reaches";

    interface = mkOption {
      type = types.str;
      example = "wlp192s0";
      description = "Wireless interface that runs the access point.";
    };

    ssid = mkOption {
      type = types.str;
      example = "my-hotspot";
      description = "SSID of the access point, and the name of its iwd profile.";
    };

    hidden = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Leave the SSID out of beacons and do not answer wildcard probes
        (`[General].Hidden`, from patches/iwd/). Clients then join by adding
        the SSID as a hidden network.
      '';
    };

    channel = mkOption {
      type = types.ints.positive;
      # Outside DFS, and with its 80 MHz block (36-48) usable the patched iwd
      # runs at 80 MHz.
      default = 36;
      description = "Wi-Fi channel of the access point.";
    };

    address = mkOption {
      type = types.str;
      default = "192.168.200.1";
      description = ''
        Address of the access point in its /24. Clients get leases from that
        /24, with this address as router and DNS server.
      '';
    };

    sopsFile = mkOption {
      type = types.path;
      description = "sops file whose `wifi-ap-passphrase` key is the WPA2 passphrase.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.networking.wireless.iwd.enable;
        message = "dev.johnrinehart.wifiAccessPoint needs iwd (dev.johnrinehart.network.manager = \"iwd\").";
      }
    ];

    # Clients leave masqueraded as this machine through whichever interface
    # its own routing picks (main table, Tailscale's table 52, Nebula's
    # routes), so they reach exactly what the machine reaches, new interfaces
    # included, and no peer network ever sees or routes back the AP subnet.
    # Nothing is forwarded back out the access point itself.
    #
    # The NAT options cannot say "any interface but this one", so the module
    # only provides the chains (and IP forwarding); the rules are here.
    networking.nat = {
      enable = true;
      extraCommands = ''
        iptables -w -t filter -A nixos-filter-forward -i ${cfg.interface} ! -o ${cfg.interface} -j ACCEPT
        iptables -w -t nat -A nixos-nat-post -s ${subnet} ! -o ${cfg.interface} -j MASQUERADE
      '';
    };

    # Tailscale's `lookup 52` rule precedes the main table: an accepted subnet
    # route covering the AP subnet would send replies to the clients into the
    # tailnet. Pin the AP subnet to its connected route ahead of it.
    networking.localCommands = ''
      ip rule del priority 5200 2>/dev/null || true
      ip rule add priority 5200 to ${subnet} lookup main
    '';

    # Clients resolve through this machine's systemd-resolved, so they get its
    # split DNS: MagicDNS, the Nebula lighthouse's zones, the wired network's
    # resolver.
    services.resolved.settings.Resolve.DNSStubListenerExtra = cfg.address;

    # DHCP (iwd) and DNS (resolved) for the access point's clients.
    networking.firewall.interfaces.${cfg.interface} = {
      allowedUDPPorts = [
        53
        67
      ];
      allowedTCPPorts = [ 53 ];
    };

    sops.secrets.wifi-ap-passphrase.sopsFile = cfg.sopsFile;

    # The address is fixed so the NAT and resolved rules above match; the
    # router defaults to it (patches/iwd/).
    sops.templates."iwd-ap-${cfg.ssid}" = {
      path = "/var/lib/iwd/ap/${cfg.ssid}.ap";
      mode = "0600";
      content = ''
        [General]
        Channel=${toString cfg.channel}
      ''
      + lib.optionalString cfg.hidden ''
        Hidden=true
      ''
      + ''

        [Security]
        Passphrase=${config.sops.placeholder.wifi-ap-passphrase}

        [IPv4]
        Address=${cfg.address}
        Netmask=255.255.255.0
        DNSList=${cfg.address}
      '';
    };
  };
}
