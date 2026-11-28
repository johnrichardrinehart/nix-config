{
  inputs,
  lib,
  pkgs,
  ...
}:
let
  psiPkg = pkgs.callPackage ../packages/psi.nix { psiSrc = inputs.psi; };
  rmuxDeckPkg = pkgs.callPackage ../packages/rmux-deck.nix {
    rmuxSrc = inputs.rmux;
    rmuxDeckSrc = inputs.rmux-deck;
  };
in
{
  # Shared fleet MixOS configuration for Yiming UZ801 v3 sticks.
  # Every host-specific value (hostname, DDNS record, own lighthouse IP/port/site,
  # and Nebula/TLS/Cloudflare secrets) lives under /state so all UZ801 nodes run
  # the exact same uz801-wifi.img store path and SHA-256 hash.
  uz801 = {
    hostName = "uz801";
    lte.enable = false;
    rootPassword = null;
    authorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ61iahx0HtGVD0qtBFIr8nTPivNxQimrqaloBazYCPK john@nixos"
    ];
    ntp.servers = [
      "time.cloudflare.com"
      "pool.ntp.org"
    ];
    led = {
      # 6-bit status sequence (green = 1, blue = 0):
      #   1: wifi        wlan0 carrier up + IPv4 lease
      #   2: nebula      nebula peer service + nebula.mycelium IPv4
      #   3: lighthouse  nebula-lighthouse service + nebula.lh IPv4
      #   4: registry    nebula-registry service + :443 HTTPS + 127.0.0.1:53 DNS
      #   5: ddns        cloudflare-ddns service + last update succeeded
      #   6: system      dropbear + uz801-thermd + A/B committed + CPU < 85 C
      # Boot window: every 5s for 60s. Healthy: dark, aligned to :00:03 / :05:03
      # every 300s. Fault: red blink every 1.5s, bitmask every 30s.
      checks = [
        {
          name = "wifi";
          command = ''[ "$(cat /sys/class/net/wlan0/carrier 2>/dev/null)" = 1 ] && ip -4 addr show dev wlan0 2>/dev/null | grep -q "inet "'';
        }
        {
          name = "nebula";
          command = ''sv check /var/service/nebula >/dev/null 2>&1 && ip -4 addr show dev nebula.mycelium 2>/dev/null | grep -q "inet "'';
        }
        {
          name = "lighthouse";
          command = ''sv check /var/service/nebula-lighthouse >/dev/null 2>&1 && ip -4 addr show dev nebula.lh 2>/dev/null | grep -q "inet "'';
        }
        {
          name = "registry";
          command = ''sv check /var/service/nebula-registry >/dev/null 2>&1 && grep -q ":01BB 00000000:0000 0A " /proc/net/tcp && grep -q "0100007F:0035 " /proc/net/udp'';
        }
        {
          name = "ddns";
          command = ''sv check /var/service/cloudflare-ddns >/dev/null 2>&1 && [ -s /run/cf-ddns.last_ip ] && [ "$(cat /run/cf-ddns.status 2>/dev/null)" = ok ]'';
        }
        {
          name = "system";
          command = ''sv check /var/service/dropbear >/dev/null 2>&1 && sv check /var/service/uz801-thermd >/dev/null 2>&1 && { ! grep -q "uz801\.pending=1" /proc/cmdline 2>/dev/null || [ -f /run/uz801-ab-committed ]; } && t3=$(cat /sys/class/thermal/thermal_zone3/temp 2>/dev/null || echo 0) && t4=$(cat /sys/class/thermal/thermal_zone4/temp 2>/dev/null || echo 0) && [ "$t3" -lt 85000 ] && [ "$t4" -lt 85000 ]'';
        }
      ];
    };
  };

  dev.johnrinehart.mycelium = {
    enable = true;
    role = "peer";
    identityFile = "/state/nebula/identity.env";
    firewall.allowPeerHTTPS = true;
    lighthouseService = {
      enable = true;
      relay.enable = true;
    };
    registry = {
      enable = true;
      dnsPort = 53;
      staticRecords = {
        lighthouse = "10.77.0.1";
        lighthouse-uz801-0 = "10.77.0.10";
        lighthouse-uz801-1 = "10.77.0.12";
      };
    };
  };

  dev.johnrinehart.cloudflareDdns = {
    enable = true;
    recordName = null;
    zoneName = "johnrinehart.dev";
    ttl = 120;
    proxied = false;
  };

  packages = [
    (lib.getBin psiPkg.curl)
    psiPkg
    rmuxDeckPkg
    rmuxDeckPkg.rmux
  ];

  etc."profile".source = pkgs.writeText "profile" ''
    export EDITOR="''${EDITOR:-vi}"
    export VISUAL="''${VISUAL:-vi}"
    export CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
    export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
  '';
}
