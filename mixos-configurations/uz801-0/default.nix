{
  imports = [ ../uz801-common.nix ];

  # Host-side deploy metadata only (never baked into the shared uz801-wifi.img):
  # - `nebula`: uz801-0 (10.77.0.11/24, group `peer`)
  # - `nebula-lighthouse`: lighthouse-uz801-0 (10.77.0.10/24, UDP 4242)
  dev.johnrinehart.mycelium = {
    sopsFile = ../../secrets/uz801-0.yaml;
    registry.tls.sopsFile = ../../secrets/uz801-0.yaml;
  };

  dev.johnrinehart.cloudflareDdns.sopsFile = ../../secrets/uz801-0.yaml;

  sops.stateFiles = {
    hostname = {
      path = "/state/hostname";
      content = "uz801-0\n";
    };
    cloudflare-ddns-env = {
      path = "/state/cloudflare-ddns.env";
      content = ''
        CF_RECORD_NAME="uz801-0.nebula.johnrinehart.dev"
      '';
    };
    nebula-identity-env = {
      path = "/state/nebula/identity.env";
      content = ''
        LH_ADDRESS="10.77.0.10"
        LH_LISTEN_PORT="4242"
        LH_SITE="lighthouse-uz801-0.mycelium.nebula.johnrinehart.dev"
      '';
    };
  };
}
