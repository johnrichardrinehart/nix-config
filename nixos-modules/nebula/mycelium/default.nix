{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.mycelium;
  network = "mycelium";
  lighthouse = cfg.lighthouse.address;
  peerRules = rules: map (rule: rule // { group = cfg.peerGroup; }) rules;
  toLighthouse = proto: port: {
    inherit port proto;
    cidr = "${lighthouse}/32";
  };
  portRules = lib.types.listOf (
    lib.types.submodule {
      options = {
        port = lib.mkOption { type = lib.types.str; };
        proto = lib.mkOption {
          type = lib.types.enum [
            "any"
            "tcp"
            "udp"
            "icmp"
          ];
        };
      };
    }
  );
in
{
  imports = [
    ../dns.nix
    ../registry.nix
  ];

  options.dev.johnrinehart.mycelium = {
    enable = lib.mkEnableOption "Mycelium VPN policy";
    role = lib.mkOption {
      type = lib.types.enum [
        "peer"
        "lighthouse"
      ];
      default = "peer";
      description = "This host's role in the Mycelium VPN.";
    };
    ca = lib.mkOption {
      type = lib.types.str;
      description = "Path to the Nebula CA certificate bundle.";
    };
    cert = lib.mkOption {
      type = lib.types.str;
      description = "Path to this host's Nebula certificate.";
    };
    key = lib.mkOption {
      type = lib.types.str;
      description = "Path to this host's Nebula private key.";
    };
    peerGroup = lib.mkOption {
      type = lib.types.str;
      default = "peer";
      description = "Certificate group that permits connections between Mycelium peers.";
    };
    blocklist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = import ./blocklist.nix;
      description = "Revoked Mycelium certificate fingerprints.";
    };
    lighthouse = {
      address = lib.mkOption {
        type = lib.types.str;
        default = "10.77.0.1";
        description = "Mycelium lighthouse overlay address.";
      };
      endpoint = lib.mkOption {
        type = lib.types.str;
        default = "nebula-lighthouse.johnrinehart.dev:4242";
        description = "Mycelium lighthouse public host and UDP port.";
      };
    };
    firewall = {
      inbound = lib.mkOption {
        type = portRules;
        default = [
          {
            port = "any";
            proto = "icmp";
          }
          {
            port = "22";
            proto = "tcp";
          }
        ];
        description = "Ports that Mycelium peers can open on this host.";
      };
      peerSshPorts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "22" ];
        description = "TCP ports this host can open for SSH to Mycelium peers.";
      };
      allowPeerHTTPS = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Permit outbound HTTPS connections to Mycelium peers.";
      };
    };
    trustCA = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Install the Mycelium TLS CA in the system trust store.";
      };
      bundle = lib.mkOption {
        type = lib.types.path;
        default = ./mycelium-tls-ca.crt;
        description = "Public TLS CA bundle trusted for Mycelium HTTPS services.";
      };
    };
    registry = {
      consolePort = lib.mkOption {
        type = lib.types.port;
        default = 2222;
        description = "Localhost port for the Mycelium lighthouse debug console.";
      };
      upstreamResolvers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Resolvers for DNS queries outside the private Mycelium zones.";
      };
      acme = {
        dnsProvider = lib.mkOption {
          type = lib.types.str;
          default = "cloudflare";
          description = "DNS provider for the Mycelium registry certificate.";
        };
        environmentFile = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/lighthouse-acme/cloudflare.env";
          description = "Credentials for the registry certificate DNS challenge.";
        };
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        services.nebula.networks.${network} = {
          inherit (cfg) ca cert key;
          settings = lib.optionalAttrs (cfg.blocklist != [ ]) { pki.blocklist = cfg.blocklist; };
        };
        security.pki.certificateFiles = lib.mkIf cfg.trustCA.enable [ cfg.trustCA.bundle ];
      }
      (lib.mkIf (cfg.role == "peer") {
        services.nebula.networks.${network} = {
          lighthouses = [ lighthouse ];
          staticHostMap.${lighthouse} = [ cfg.lighthouse.endpoint ];
          listen.port = 0;
          relays = [ lighthouse ];
          settings.punchy = {
            punch = true;
            respond = true;
          };
          # The lighthouse lacks the peer group and cannot initiate peer connections.
          firewall.inbound = peerRules cfg.firewall.inbound;
          firewall.outbound =
            lib.optionals cfg.firewall.allowPeerHTTPS (peerRules [
              {
                port = "443";
                proto = "tcp";
              }
            ])
            ++ [
              (toLighthouse "icmp" "any")
              (toLighthouse "tcp" "22")
              (toLighthouse "udp" "53")
              (toLighthouse "tcp" "53")
              (toLighthouse "tcp" "443")
            ]
            ++ peerRules (
              [
                {
                  port = "any";
                  proto = "icmp";
                }
              ]
              ++ map (port: {
                inherit port;
                proto = "tcp";
              }) cfg.firewall.peerSshPorts
            );
        };
        dev.johnrinehart.nebula.networks.${network}.dns = {
          enable = true;
          server = lighthouse;
          domains = [
            "mycelium.nebula.johnrinehart.dev"
            "mycelium.internal"
          ];
        };
      })
      (lib.mkIf (cfg.role == "lighthouse") {
        services.nebula.networks.${network} = {
          isLighthouse = true;
          isRelay = true;
          listen.port = 4242;
          # The lighthouse only accepts peer connections. Its outbound rules stay empty.
          firewall.inbound = peerRules (
            cfg.firewall.inbound
            ++ [
              {
                port = "53";
                proto = "udp";
              }
              {
                port = "53";
                proto = "tcp";
              }
              {
                port = "443";
                proto = "tcp";
              }
            ]
          );
        };
        dev.johnrinehart.nebula.registry = {
          enable = true;
          parentDomain = "nebula.johnrinehart.dev";
          inherit (cfg.registry) acme upstreamResolvers;
          networks.${network} = {
            address = lighthouse;
            inherit (cfg.registry) consolePort;
            aliases = [ "mycelium.internal" ];
          };
        };
        # Credentials arrive outside Nix. Check the certificate group on every start.
        systemd.services."nebula@${network}".serviceConfig.ExecStartPre = [
          (pkgs.writeShellScript "nebula-${network}-lighthouse-not-peer" ''
            set -euo pipefail
            cert=${lib.escapeShellArg config.services.nebula.networks.${network}.cert}
            groups=$(${
              lib.getExe' config.services.nebula.networks.${network}.package "nebula-cert"
            } print -json -path "$cert" | ${lib.getExe pkgs.jq} -r '(if type == "array" then .[0] else . end).details.groups // [] | .[]')
            if printf '%s\n' "$groups" | grep -qxF ${lib.escapeShellArg cfg.peerGroup}; then
              echo "refusing to start: lighthouse certificate $cert is in group '${cfg.peerGroup}'; re-sign it without that group" >&2
              exit 1
            fi
          '')
        ];
      })
    ]
  );
}
