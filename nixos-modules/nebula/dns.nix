{ config, lib, ... }:
let
  networks = config.dev.johnrinehart.nebula.networks;
  enabled = lib.filterAttrs (_: net: net.dns.enable) networks;
in
{
  options.dev.johnrinehart.nebula.networks = lib.mkOption {
    default = { };
    description = "Per-network Nebula integration with systemd-resolved.";
    type = lib.types.attrsOf (
      lib.types.submodule {
        options.dns = {
          enable = lib.mkEnableOption "per-link DNS routing for this Nebula network";
          server = lib.mkOption {
            type = lib.types.str;
            description = "DNS server address on this Nebula network.";
          };
          domains = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Private DNS zones routed to this network's DNS server.";
          };
        };
      }
    );
  };

  config = lib.mkIf (enabled != { }) {
    services.resolved.enable = true;
    systemd.services = lib.mapAttrs' (
      name: net:
      let
        configured = config.services.nebula.networks.${name}.tun.device;
        device = if configured != null then configured else "nebula.${name}";
        resolvectl = "${config.systemd.package}/bin/resolvectl";
        domains = lib.escapeShellArgs (map (domain: "~${domain}") net.dns.domains);
      in
      lib.nameValuePair "nebula@${name}" {
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        # Resolved drops link settings when Nebula removes its interface.
        # The privileged commands restore them after each interface creation.
        serviceConfig.ExecStartPost = [
          "+${resolvectl} dns ${device} ${net.dns.server}"
          "+${resolvectl} domain ${device} ${domains}"
          "+${resolvectl} default-route ${device} false"
        ];
      }
    ) enabled;
  };
}
