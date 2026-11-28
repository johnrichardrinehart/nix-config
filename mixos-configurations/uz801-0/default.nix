{
  # First Yiming UZ801 v3 stick running two isolated Nebula identities:
  # - `nebula` (peer, 10.77.0.11/24, group `peer`, TUN `nebula.mycelium`,
  #   registered as `uz801-0.mycelium.internal`).
  # - `nebula-lighthouse` (strict headless lighthouse + relay, 10.77.0.10/24,
  #   no `peer` group, `tun.disabled = true`, UDP 4242 at
  #   `uz801-0.nebula.johnrinehart.dev:4242`).
  # All Nebula credentials and `cloudflare-api-token` live in
  # secrets/uz801-0.yaml and decrypt into /run/secrets at boot.
  uz801 = {
    hostName = "uz801-0";
    lte.enable = false;
    authorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ61iahx0HtGVD0qtBFIr8nTPivNxQimrqaloBazYCPK john@nixos"
    ];
  };

  dev.johnrinehart.mycelium = {
    enable = true;
    role = "peer";
    sopsFile = ../../secrets/uz801-0.yaml;
    extraLighthouses = [
      {
        address = "10.77.0.10";
        endpoint = "uz801-0.nebula.johnrinehart.dev:4242";
        relay = true;
      }
    ];
    lighthouseService = {
      enable = true;
      relay.enable = true;
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
