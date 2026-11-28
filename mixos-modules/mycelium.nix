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
  regCfg = cfg.registry;
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
    {
      port = "53";
      proto = "udp";
      cidr = "${lh.address}/32";
    }
    {
      port = "53";
      proto = "tcp";
      cidr = "${lh.address}/32";
    }
    {
      port = "443";
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
    # Enforce that a strict lighthouse certificate never carries the peer group
    # when nebula-cert is present on-device (uz801-deploy also enforces this on the host).
    if [ -x ${config.uz801.nebula.package}/bin/nebula-cert ] && ${config.uz801.nebula.package}/bin/nebula-cert print -json -path ${lib.escapeShellArg certPath} \
      | grep -Eq '"groups":\[[^]]*"${cfg.peerGroup}"'; then
      echo "refusing to start: lighthouse certificate ${certPath} is in group '${cfg.peerGroup}'; re-sign it without that group" >&2
      exit 1
    fi
  '';

  # Strip Go symbol/DWARF tables (-s -w) and build only cmd/nebula (omitting the
  # 6.8 MiB nebula-cert CLI) so Nebula adds ~3 MiB compressed to the EROFS image.
  slimNebula = pkgs.nebula.overrideAttrs (old: {
    subPackages = [ "cmd/nebula" ];
    ldflags = (old.ldflags or [ ]) ++ [
      "-s"
      "-w"
    ];
  });

  nebulaFormat = pkgs.buildPackages.formats.yaml { };
  jsonFormat = pkgs.buildPackages.formats.json { };
  consoleDir = "/state/nebula-console";
  regStateDir = "/state/nebula-registry";
  consoleUser = "registry";
  regPackage = regCfg.package;
  registryConfig = jsonFormat.generate "nebula-registry.json" {
    stateDir = regStateDir;
    inherit consoleUser;
    inherit (regCfg)
      pollInterval
      offlineAfterPolls
      eventRetentionDays
      upstreamResolvers
      ;
    ssh = "/sbin/dbclient";
    tls = {
      inherit (regCfg.tls) certFile keyFile;
      port = regCfg.httpsPort;
    };
    networks.mycelium = {
      inherit (regCfg)
        address
        interface
        consolePort
        dnsPort
        domain
        aliases
        site
        adminGroups
        staticRecords
        ;
    };
  };

  consolePrepScript = ''
    mkdir -p ${consoleDir} ${regStateDir} /run/nebula-lighthouse.d
    chmod 0700 ${consoleDir}
    chmod 0750 ${regStateDir}
    if [ ! -s ${consoleDir}/host_key ]; then
      ${regPackage}/bin/nebula-registry --keygen-ecdsa ${consoleDir}/host_key
    fi
    if [ ! -s ${regStateDir}/client_key ]; then
      /sbin/dropbearkey -t ed25519 -f ${regStateDir}/client_key >/dev/null
      chmod 0600 ${regStateDir}/client_key
    fi
    client_pub=$(/sbin/dropbearkey -y -f ${regStateDir}/client_key | awk '/^ssh-ed25519 / {print $1 " " $2}')
    ln -sf /etc/nebula/lighthouse.yml /run/nebula-lighthouse.d/00-base.yml
    printf '{"sshd":{"enabled":true,"listen":"127.0.0.1:%s","host_key":"%s/host_key","authorized_users":[{"user":"%s","keys":["%s"]}]}}\n' \
      ${toString regCfg.consolePort} ${consoleDir} ${consoleUser} "$client_pub" \
      > /run/nebula-lighthouse.d/50-console.yml
  '';

  regServiceRun = pkgs.writeScript "nebula-registry-run" ''
    #!/bin/sh
    mkdir -p ${regStateDir}
    chmod 0750 ${regStateDir}
    ${lib.optionalString (regCfg.tls.sopsFile == null) ''
      if [ ! -s ${lib.escapeShellArg regCfg.tls.certFile} ] || [ ! -s ${lib.escapeShellArg regCfg.tls.keyFile} ]; then
        ${regPackage}/bin/nebula-registry --self-signed \
          ${lib.escapeShellArg regCfg.tls.certFile} \
          ${lib.escapeShellArg regCfg.tls.keyFile} \
          ${lib.escapeShellArg regCfg.site}
      fi
    ''}
    while [ ! -r ${lib.escapeShellArg regCfg.tls.certFile} ] \
       || [ ! -r ${lib.escapeShellArg regCfg.tls.keyFile} ] \
       || [ ! -r ${regStateDir}/client_key ] \
       ${
         lib.optionalString (
           regCfg.interface != ""
         ) "|| ! ip link show ${lib.escapeShellArg regCfg.interface} >/dev/null 2>&1"
       }; do
      sleep 1
    done
    exec ${regPackage}/bin/nebula-registry --config /etc/nebula/registry.json
  '';

  lhTunDev = "nebula.lh";
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
    # When the peer registry is enabled on the lighthouse, open a dedicated
    # lighthouse TUN (nebula.lh) so peers reach HTTPS/DNS on the lighthouse's
    # own overlay IP rather than the colocated peer identity.
    tun =
      if regCfg.enable then
        {
          disabled = false;
          dev = lhTunDev;
          drop_local_broadcast = false;
          drop_multicast = false;
          tx_queue = 500;
          mtu = 1300;
        }
      else
        {
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
      inbound = lib.optionals regCfg.enable (
        peerRules (
          [
            {
              port = "any";
              proto = "icmp";
            }
            {
              port = toString regCfg.httpsPort;
              proto = "tcp";
            }
          ]
          ++ lib.optionals (regCfg.dnsPort > 0) [
            {
              port = toString regCfg.dnsPort;
              proto = "udp";
            }
            {
              port = toString regCfg.dnsPort;
              proto = "tcp";
            }
          ]
        )
      );
      outbound = [ ];
    };
  };

  lhRouteMetricFix = ''
    # Lower-priority metric on the lighthouse TUN route so general host traffic
    # continues to originate from the colocated peer TUN (nebula.mycelium),
    # while nebula-registry sockets bound via SO_BINDTODEVICE(${lhTunDev}) still
    # reply cleanly through ${lhTunDev}.
    (
      i=0
      while [ "$i" -lt 40 ]; do
        subnet=$(ip -4 route show dev ${lhTunDev} 2>/dev/null | awk 'NR==1 {print $1}')
        if [ -n "$subnet" ]; then
          ip route replace "$subnet" dev ${lhTunDev} src ${lib.escapeShellArg regCfg.address} metric 200 2>/dev/null || true
          ip route del "$subnet" dev ${lhTunDev} proto kernel 2>/dev/null || true
          break
        fi
        sleep 0.5
        i=$((i + 1))
      done
    ) &
  '';

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
    ${lib.optionalString regCfg.enable consolePrepScript}
    ${lib.optionalString regCfg.enable lhRouteMetricFix}
    exec ${config.uz801.nebula.package}/bin/nebula -config ${
      if regCfg.enable then "/run/nebula-lighthouse.d" else "/etc/nebula/lighthouse.yml"
    }
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
        When set, `uz801-deploy` decrypts them on the deploying host into
        /state/secrets and wires ca, cert, and key automatically.
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
      default = [
        {
          address = "10.77.0.10";
          endpoint = "uz801-0.nebula.johnrinehart.dev:4242";
          relay = true;
        }
      ];
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

    registry = {
      enable = lib.mkEnableOption "lightweight C Nebula peer registry dashboard on this host";

      package = lib.mkOption {
        type = lib.types.package;
        # Match nixos-uz801's lib-only mbedtls override so the image reuses the
        # existing mbedtls store path instead of pulling a second 14 MiB copy.
        default = pkgs.callPackage ../packages/nebula-registry {
          mbedtls = pkgs.mbedtls.overrideAttrs (old: {
            cmakeFlags = (old.cmakeFlags or [ ]) ++ [
              "-DENABLE_PROGRAMS=OFF"
              "-DENABLE_TESTING=OFF"
            ];
            postConfigure = "";
          });
        };
        defaultText = lib.literalExpression "pkgs.callPackage ../packages/nebula-registry { }";
        description = "The nebula-registry package to run.";
      };

      address = lib.mkOption {
        type = lib.types.str;
        description = "Overlay IPv4 address of the lighthouse TUN interface to bind HTTPS and DNS.";
      };

      interface = lib.mkOption {
        type = lib.types.str;
        default = lhTunDev;
        description = "Network interface bound via SO_BINDTODEVICE so replies leave via the lighthouse TUN.";
      };

      staticRecords = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Static DNS label-to-IPv4 records served alongside live Nebula peers.";
      };

      site = lib.mkOption {
        type = lib.types.str;
        description = "HTTPS hostname for this host's registry view.";
      };

      domain = lib.mkOption {
        type = lib.types.str;
        default = "mycelium.nebula.johnrinehart.dev";
        description = "Primary DNS zone served when dnsPort is nonzero.";
      };

      aliases = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "mycelium.internal" ];
        description = "Additional private DNS zones served when dnsPort is nonzero.";
      };

      consolePort = lib.mkOption {
        type = lib.types.port;
        default = 2222;
        description = "Localhost SSH port for the headless lighthouse debug console.";
      };

      httpsPort = lib.mkOption {
        type = lib.types.port;
        default = 443;
        description = "HTTPS port for the peer registry web UI and JSON API.";
      };

      dnsPort = lib.mkOption {
        type = lib.types.int;
        default = 0;
        description = "DNS port to serve (0 disables the DNS listener).";
      };

      adminGroups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "registry-admin" ];
        description = "Certificate groups permitted to archive and restore offline peers.";
      };

      pollInterval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = "Seconds between debug console polls.";
      };

      offlineAfterPolls = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = "Missed polls before a peer is marked offline.";
      };

      eventRetentionDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 365;
        description = "Days of peer events to keep.";
      };

      upstreamResolvers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Upstream DNS resolvers when dnsPort is nonzero.";
      };

      tls = {
        sopsFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Optional SOPS file holding the HTTPS certificate and key.";
        };
        certKey = lib.mkOption {
          type = lib.types.str;
          default = "tls-cert";
          description = "Top-level YAML key in tls.sopsFile for the HTTPS certificate.";
        };
        keyKey = lib.mkOption {
          type = lib.types.str;
          default = "tls-key";
          description = "Top-level YAML key in tls.sopsFile for the HTTPS private key.";
        };
        certFile = lib.mkOption {
          type = lib.types.str;
          default = "${regStateDir}/server.crt";
          description = "Runtime path to the HTTPS certificate.";
        };
        keyFile = lib.mkOption {
          type = lib.types.str;
          default = "${regStateDir}/server.key";
          description = "Runtime path to the HTTPS private key.";
        };
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        uz801.extraCaCertificates = lib.mkIf cfg.trustCA.enable [ cfg.trustCA.bundle ];

        uz801.nebula = {
          enable = true;
          package = lib.mkDefault slimNebula;
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
          (lib.mkIf (regCfg.enable && regCfg.tls.sopsFile != null) {
            nebula-registry-tls-cert = {
              inherit (regCfg.tls) sopsFile;
              key = regCfg.tls.certKey;
              mode = "0444";
            };
            nebula-registry-tls-key = {
              inherit (regCfg.tls) sopsFile;
              key = regCfg.tls.keyKey;
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
      (lib.mkIf regCfg.enable {
        assertions = [
          {
            assertion = lhSvc.enable;
            message = "dev.johnrinehart.mycelium.registry currently requires dev.johnrinehart.mycelium.lighthouseService.enable.";
          }
          {
            assertion = regCfg.tls.sopsFile == null || options ? sops;
            message = "dev.johnrinehart.mycelium.registry.tls.sopsFile requires mixosModules.sops.";
          }
        ];

        dev.johnrinehart.mycelium.registry.tls = lib.mkIf (regCfg.tls.sopsFile != null) {
          certFile = config.sops.secrets.nebula-registry-tls-cert.path;
          keyFile = config.sops.secrets.nebula-registry-tls-key.path;
        };

        etc."nebula/registry.json".source = registryConfig;
        services.nebula-registry.run = regServiceRun;
      })
    ]
  );
}
