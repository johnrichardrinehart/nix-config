{
  imports = [ ../uz801-common.nix ];

  # Host-side deploy metadata only (never baked into the shared uz801-wifi.img):
  # - `nebula`: uz801-1 (10.77.0.13/24, group `peer`)
  # - `nebula-lighthouse`: lighthouse-uz801-1 (10.77.0.12/24, UDP 4243)
  dev.johnrinehart.mycelium = {
    sopsFile = ../../secrets/uz801-1.yaml;
    registry.tls.sopsFile = ../../secrets/uz801-1.yaml;
  };

  dev.johnrinehart.cloudflareDdns.sopsFile = ../../secrets/uz801-1.yaml;

  sops.stateFiles = {
    hostname = {
      path = "/state/hostname";
      content = "uz801-1\n";
    };
    cloudflare-ddns-env = {
      path = "/state/cloudflare-ddns.env";
      content = ''
        CF_RECORD_NAME="uz801-1.nebula.johnrinehart.dev"
      '';
    };
    nebula-identity-env = {
      path = "/state/nebula/identity.env";
      content = ''
        LH_ADDRESS="10.77.0.12"
        LH_LISTEN_PORT="4243"
        LH_SITE="lighthouse-uz801-1.mycelium.nebula.johnrinehart.dev"
      '';
    };
  };
}
