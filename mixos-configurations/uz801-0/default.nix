{
  # First Yiming UZ801 v3 stick: strict Mycelium lighthouse + relay
  # (`10.77.0.10/24`, no `peer` group, empty outbound rules).
  # Nebula credentials (`nebula-ca`, `nebula-cert`, `nebula-key`) and the
  # Cloudflare DDNS token (`cloudflare-api-token`) live in secrets/uz801-0.yaml
  # and are decrypted into /run/secrets at boot using /state/sops/age-key.txt.
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
    sopsFile = ../../secrets/uz801-0.yaml;
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
