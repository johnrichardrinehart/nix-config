{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.mycelium;
  lhSvc = cfg.lighthouseService;
  lighthouse = cfg.lighthouse.address;
  extraRelayAddrs = map (lh: lh.address) (builtins.filter (lh: lh.relay) cfg.extraLighthouses);
  allLighthouseAddrs = [ lighthouse ] ++ map (lh: lh.address) cfg.extraLighthouses;
  allStaticHostMap = {
    ${lighthouse} = [ cfg.lighthouse.endpoint ];
  }
  // builtins.listToAttrs (
    map (lh: {
      name = lh.address;
      value = [ lh.endpoint ];
    }) cfg.extraLighthouses
  );
  peerRules = rules: map (rule: rule // { group = cfg.peerGroup; }) rules;
  toLighthouse = proto: port: {
    inherit port proto;
    cidr = "${lighthouse}/32";
  };
  toExtraLighthouses = lib.concatMap (lh: [
    {
      port = "any";
      proto = "icmp";
      cidr = "${lh.address}/32";
    }
    {
      port = "22";
      proto = "tcp";
      cidr = "${lh.address}/32";
    }
  ]) cfg.extraLighthouses;
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
  extraLighthouseType = lib.types.submodule {
    options = {
      address = lib.mkOption {
        type = lib.types.str;
        description = "Secondary lighthouse overlay IPv4 address.";
      };
      endpoint = lib.mkOption {
        type = lib.types.str;
        description = "Secondary lighthouse underlay host and UDP port.";
      };
      relay = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Use this secondary lighthouse as a Nebula relay.";
      };
    };
  };
  commonSettings = {
    listen = {
      host = "0.0.0.0";
      port = cfg.listenPort;
    };
    punchy = {
      punch = true;
      respond = true;
    };
    tunnels = {
      drop_inactive = true;
      inactivity_timeout = "5m";
    };
    timers = {
      connection_alive_interval = 2;
      pending_deletion_interval = 3;
    };
    tun = {
      disabled = false;
      dev = "nebula.mycelium";
      drop_local_broadcast = false;
      drop_multicast = false;
      tx_queue = 500;
      mtu = 1300;
    };
    logging = {
      level = "info";
      format = "text";
    };
    firewall = {
      outbound_action = "drop";
      inbound_action = "drop";
      conntrack = {
        tcp_timeout = "12m";
        udp_timeout = "3m";
        default_timeout = "10m";
      };
      inbound = peerRules cfg.firewall.inbound;
      outbound =
        if cfg.role == "lighthouse" then
          [ ]
        else
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
          ++ toExtraLighthouses
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
  };
  roleSettings =
    if cfg.role == "lighthouse" then
      {
        lighthouse.am_lighthouse = true;
        relay = {
          am_relay = cfg.relay.enable;
          use_relays = false;
        };
      }
    else
      {
        static_host_map = allStaticHostMap;
        lighthouse = {
          am_lighthouse = false;
          hosts = allLighthouseAddrs;
        };
        relay = {
          am_relay = false;
          use_relays = true;
          relays = [ lighthouse ] ++ extraRelayAddrs;
        };
      };

  lhCertGuard = certPath: ''
    # Enforce that a strict lighthouse certificate never carries the peer group.
    if ${config.uz801.nebula.package}/bin/nebula-cert print -json -path ${lib.escapeShellArg certPath} \
      | grep -Eq '"groups":\[[^]]*"${cfg.peerGroup}"'; then
      echo "refusing to start: lighthouse certificate ${certPath} is in group '${cfg.peerGroup}'; re-sign it without that group" >&2
      exit 1
    fi
  '';

  nebulaFormat = pkgs.buildPackages.formats.yaml { };
  lhServiceConfig = nebulaFormat.generate "nebula-lighthouse.yml" {
    pki = {
      inherit (lhSvc) ca cert key;
    }
    // lib.optionalAttrs (cfg.blocklist != [ ]) {
      inherit (cfg) blocklist;
    };
    lighthouse.am_lighthouse = true;
    listen = {
      host = "0.0.0.0";
      port = lhSvc.listenPort;
    };
    punchy = {
      punch = true;
      respond = true;
    };
    relay = {
      am_relay = lhSvc.relay.enable;
      use_relays = false;
    };
    tunnels = {
      drop_inactive = true;
      inactivity_timeout = "5m";
    };
    timers = {
      connection_alive_interval = 2;
      pending_deletion_interval = 3;
    };
    # Headless lighthouse/relay: no TUN interface so it never conflicts with
    # the host's peer TUN route on 10.77.0.0/24.
    tun = {
      disabled = true;
    };
    logging = {
      level = "info";
      format = "text";
    };
    firewall = {
      outbound_action = "drop";
      inbound_action = "drop";
      conntrack = {
        tcp_timeout = "12m";
        udp_timeout = "3m";
        default_timeout = "10m";
      };
      inbound = [ ];
      outbound = [ ];
    };
  };

  lhServiceRun = pkgs.writeScript "nebula-lighthouse-run" ''
    #!/bin/sh
    while [ ! -r ${lib.escapeShellArg lhSvc.ca} ] \
       || [ ! -r ${lib.escapeShellArg lhSvc.cert} ] \
       || [ ! -r ${lib.escapeShellArg lhSvc.key} ] \
       || ! ip -4 route show default 2>/dev/null | grep -q '^default'; do
      sleep 1
    done
    # Wait briefly for ntpd to step the RTC-less clock so cert validity passes on first handshake.
    waited=0
    while [ "$(date +%Y)" -lt 2025 ] && [ "$waited" -lt 20 ]; do
      sleep 0.5
      waited=$((waited + 1))
    done
    ${lhCertGuard lhSvc.cert}
    exec ${config.uz801.nebula.package}/bin/nebula -config /etc/nebula/lighthouse.yml
  '';
in
{
  options.dev.johnrinehart.mycelium = {
    enable = lib.mkEnableOption "Mycelium Nebula policy for MixOS";

    role = lib.mkOption {
      type = lib.types.enum [
        "peer"
        "lighthouse"
      ];
      default = "peer";
      description = "This host's primary role in the Mycelium VPN.";
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = if cfg.role == "lighthouse" then 4242 else 0;
      defaultText = lib.literalExpression ''if cfg.role == "lighthouse" then 4242 else 0'';
      description = "UDP port the primary Nebula instance listens on (4242 for lighthouses, ephemeral 0 for peers).";
    };

    relay.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "When role is lighthouse, allow relaying peer traffic (am_relay).";
    };

    sopsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        SOPS file containing `nebula-ca`, `nebula-cert`, and `nebula-key`.
        When set, mixos-modules/sops.nix decrypts them at boot into /run/secrets
        and wires ca, cert, and key automatically.
      '';
    };

    ca = lib.mkOption {
      type = lib.types.str;
      default = "/state/nebula/ca.crt";
      description = "On-device path to the Nebula CA certificate bundle.";
    };

    cert = lib.mkOption {
      type = lib.types.str;
      default = "/state/nebula/host.crt";
      description = "On-device path to this host's Nebula certificate.";
    };

    key = lib.mkOption {
      type = lib.types.str;
      default = "/state/nebula/host.key";
      description = "On-device path to this host's Nebula private key.";
    };

    lighthouseService = {
      enable = lib.mkEnableOption "separate headless strict lighthouse Nebula process (tun.disabled = true) alongside a peer instance";

      listenPort = lib.mkOption {
        type = lib.types.port;
        default = 4242;
        description = "UDP port the separate headless lighthouse listens on.";
      };

      relay.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Allow the separate headless lighthouse to relay peer traffic (am_relay).";
      };

      sopsFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = cfg.sopsFile;
        defaultText = lib.literalExpression "config.dev.johnrinehart.mycelium.sopsFile";
        description = "SOPS file holding the headless lighthouse certificate and key.";
      };

      certKey = lib.mkOption {
        type = lib.types.str;
        default = "nebula-lighthouse-cert";
        description = "Top-level YAML key in sopsFile for the headless lighthouse certificate.";
      };

      keyKey = lib.mkOption {
        type = lib.types.str;
        default = "nebula-lighthouse-key";
        description = "Top-level YAML key in sopsFile for the headless lighthouse private key.";
      };

      ca = lib.mkOption {
        type = lib.types.str;
        default = cfg.ca;
        defaultText = lib.literalExpression "config.dev.johnrinehart.mycelium.ca";
        description = "On-device path to the Nebula CA certificate for the headless lighthouse.";
      };

      cert = lib.mkOption {
        type = lib.types.str;
        default = "/state/nebula-lighthouse/host.crt";
        description = "On-device path to the headless lighthouse certificate.";
      };

      key = lib.mkOption {
        type = lib.types.str;
        default = "/state/nebula-lighthouse/host.key";
        description = "On-device path to the headless lighthouse private key.";
      };
    };

    peerGroup = lib.mkOption {
      type = lib.types.str;
      default = "peer";
      description = "Certificate group that permits connections between Mycelium peers.";
    };

    blocklist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = import ../nixos-modules/nebula/mycelium/blocklist.nix;
      description = "Revoked Mycelium certificate fingerprints.";
    };

    lighthouse = {
      address = lib.mkOption {
        type = lib.types.str;
        default = "10.77.0.1";
        description = "Primary Mycelium lighthouse overlay address.";
      };
      endpoint = lib.mkOption {
        type = lib.types.str;
        default = "nebula-lighthouse.johnrinehart.dev:4242";
        description = "Primary Mycelium lighthouse public host and UDP port.";
      };
    };

    extraLighthouses = lib.mkOption {
      type = lib.types.listOf extraLighthouseType;
      default = [ ];
      description = "Additional Mycelium lighthouses contacted by peers.";
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
        description = "Install the Mycelium TLS CA in /etc/ssl/certs/ca-certificates.crt.";
      };
      bundle = lib.mkOption {
        type = lib.types.path;
        default = ../nixos-modules/nebula/mycelium/mycelium-tls-ca.crt;
        description = "Public TLS CA bundle trusted for Mycelium HTTPS services.";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        uz801.extraCaCertificates = lib.mkIf cfg.trustCA.enable [ cfg.trustCA.bundle ];

        uz801.nebula = {
          enable = true;
          inherit (cfg)
            ca
            cert
            key
            blocklist
            ;
          settings = lib.recursiveUpdate commonSettings roleSettings;
          preStart = lib.optionalString (cfg.role == "lighthouse") (lhCertGuard cfg.cert);
        };
      }
      (lib.optionalAttrs (options ? sops) {
        sops.secrets = lib.mkMerge [
          (lib.mkIf (cfg.sopsFile != null) {
            nebula-ca = {
              inherit (cfg) sopsFile;
              mode = "0444";
            };
            nebula-cert = {
              inherit (cfg) sopsFile;
              mode = "0444";
            };
            nebula-key = {
              inherit (cfg) sopsFile;
              mode = "0400";
            };
          })
          (lib.mkIf (lhSvc.enable && lhSvc.sopsFile != null) {
            nebula-lighthouse-cert = {
              inherit (lhSvc) sopsFile;
              key = lhSvc.certKey;
              mode = "0444";
            };
            nebula-lighthouse-key = {
              inherit (lhSvc) sopsFile;
              key = lhSvc.keyKey;
              mode = "0400";
            };
          })
        ];
      })
      (lib.mkIf (cfg.sopsFile != null) {
        assertions = [
          {
            assertion = options ? sops;
            message = "dev.johnrinehart.mycelium.sopsFile requires mixosModules.sops.";
          }
        ];
        dev.johnrinehart.mycelium = {
          ca = config.sops.secrets.nebula-ca.path;
          cert = config.sops.secrets.nebula-cert.path;
          key = config.sops.secrets.nebula-key.path;
        };
      })
      (lib.mkIf lhSvc.enable {
        assertions = [
          {
            assertion = cfg.role == "peer";
            message = "dev.johnrinehart.mycelium.lighthouseService requires role = \"peer\" so the peer and headless lighthouse do not collide on UDP port.";
          }
          {
            assertion = lhSvc.sopsFile == null || options ? sops;
            message = "dev.johnrinehart.mycelium.lighthouseService.sopsFile requires mixosModules.sops.";
          }
        ];

        dev.johnrinehart.mycelium.lighthouseService = lib.mkIf (lhSvc.sopsFile != null) {
          cert = config.sops.secrets.nebula-lighthouse-cert.path;
          key = config.sops.secrets.nebula-lighthouse-key.path;
        };

        etc."nebula/lighthouse.yml".source = lhServiceConfig;
        services.nebula-lighthouse.run = lhServiceRun;
      })
    ]
  );
}
