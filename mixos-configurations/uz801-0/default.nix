{
  # First Yiming UZ801 v3 stick: strict Mycelium lighthouse + relay
  # (`10.77.0.10/24`, no `peer` group, empty outbound rules).
  # Nebula credentials are backed up in secrets/nebula-uz801-0.yaml and
  # provisioned onto /state/nebula/{ca.crt,host.crt,host.key}.
  # Cloudflare DDNS token and record name live in /state/cloudflare-ddns.env.
  uz801 = {
    hostName = "uz801-0";
    lte.enable = false;
    authorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ61iahx0HtGVD0qtBFIr8nTPivNxQimrqaloBazYCPK john@nixos"
    ];
  };

  dev.johnrinehart.mycelium = {
    enable = true;
    role = "lighthouse";
    relay.enable = true;
  };

  dev.johnrinehart.cloudflareDdns = {
    enable = true;
    ttl = 120;
    proxied = false;
  };
}
