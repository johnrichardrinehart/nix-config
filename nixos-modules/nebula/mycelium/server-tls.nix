{ config, lib, ... }:
let
  cfg = config.dev.johnrinehart.mycelium;
  tls = cfg.serverTLS;
in
{
  options.dev.johnrinehart.mycelium.serverTLS = {
    enable = lib.mkEnableOption "a Mycelium private-hostname TLS identity for this HTTP server";
    name = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "This server's name in its Nebula certificate and private DNS zone.";
    };
    hostName = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${tls.name}.mycelium.internal";
      description = "Private HTTPS hostname covered by this server's TLS certificate.";
    };
    certFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/mycelium-tls/server.crt";
      description = "Runtime path to the server certificate signed by the Mycelium TLS CA.";
    };
    keyFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/mycelium-tls/server.key";
      description = "Runtime path to this server's private TLS key.";
    };
    group = lib.mkOption {
      type = lib.types.str;
      default = if cfg.role == "lighthouse" then "nebula-registry" else "nginx";
      description = "HTTP service group that can read the server's private TLS key.";
    };
  };

  config = lib.mkIf (cfg.enable && tls.enable) (
    lib.mkMerge [
      {
        # Deployment installs the certificate and key outside the Nix store.
        systemd.tmpfiles.rules = [
          "z ${tls.certFile} 0444 root root -"
          "z ${tls.keyFile} 0440 root ${tls.group} -"
        ];
      }
      (lib.mkIf (cfg.role == "lighthouse") {
        dev.johnrinehart.nebula.registry.tls.extraCertificates.${tls.hostName} = {
          inherit (tls) certFile keyFile;
        };
      })
    ]
  );
}
