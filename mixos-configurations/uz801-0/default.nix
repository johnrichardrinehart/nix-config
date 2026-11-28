{
  # First Yiming UZ801 v3 stick running two isolated Nebula identities:
  # - `nebula` (`peer-uz801-0`, 10.77.0.11/24, group `peer`, TUN
  #   `nebula.mycelium`, SSH/ICMP peer).
  # - `nebula-lighthouse` (`lighthouse-uz801-0`, strict lighthouse + relay,
  #   10.77.0.10/24, no `peer` group, TUN `nebula.lh`, UDP 4242 at
  #   `uz801-0.nebula.johnrinehart.dev:4242`, serving DNS :53 and the HTTPS
  #   peer registry on `10.77.0.10:443`).
  # All Nebula credentials and `cloudflare-api-token` live encrypted in
  # secrets/uz801-0.yaml and are decrypted on the deploying host into
  # /state/secrets by `nix run .#uz801-deploy`.
  uz801 = {
    hostName = "uz801-0";
    lte.enable = false;
    authorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ61iahx0HtGVD0qtBFIr8nTPivNxQimrqaloBazYCPK john@nixos"
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
    sopsFile = ../../secrets/uz801-0.yaml;
    firewall.allowPeerHTTPS = true;
    extraLighthouses = [
      {
        address = "10.77.0.10";
        # Reach the colocated headless lighthouse over loopback to avoid router NAT hairpinning.
        endpoint = "127.0.0.1:4242";
        relay = true;
      }
    ];
    lighthouseService = {
      enable = true;
      relay.enable = true;
    };
    registry = {
      enable = true;
      address = "10.77.0.10";
      dnsPort = 53;
      site = "lighthouse-uz801-0.mycelium.nebula.johnrinehart.dev";
      staticRecords.lighthouse = "10.77.0.1";
      tls.sopsFile = ../../secrets/uz801-0.yaml;
    };
  };

  dev.johnrinehart.cloudflareDdns = {
    enable = true;
    sopsFile = ../../secrets/uz801-0.yaml;
    recordName = "uz801-0.nebula.johnrinehart.dev";
    zoneName = "johnrinehart.dev";
    ttl = 120;
    proxied = false;
  };
}
