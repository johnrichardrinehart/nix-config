{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.nebula.registry;
  package = pkgs.callPackage ../../packages/nebula-registry { };
  names = lib.attrNames cfg.networks;
  stateDir = "/var/lib/nebula-registry";
  # Nebula's console host key and per-network sshd config, readable by the
  # Nebula services (group nebula-console) but not by the registry.
  consoleDir = "/var/lib/nebula-console";
  consoleUser = "registry";
  zone = name: "${name}.${cfg.parentDomain}";
  site = name: "${cfg.siteLabel}.${zone name}";
  sites = map site names;
  certName = lib.head sites;
  device =
    name:
    let
      configured = config.services.nebula.networks.${name}.tun.device;
    in
    if configured != null then configured else "nebula.${name}";

  registryConfig = (pkgs.formats.json { }).generate "nebula-registry.json" {
    inherit stateDir consoleUser;
    inherit (cfg)
      pollInterval
      offlineAfterPolls
      eventRetentionDays
      upstreamResolvers
      ;
    ssh = lib.getExe' pkgs.openssh "ssh";
    tls = {
      certFile = "/var/lib/acme/${certName}/fullchain.pem";
      keyFile = "/var/lib/acme/${certName}/key.pem";
      port = 443;
      inherit (cfg.tls) extraCertificates;
    };
    networks = lib.mapAttrs (name: net: {
      inherit (net) address consolePort;
      domain = zone name;
      inherit (net) aliases;
      site = site name;
    }) cfg.networks;
  };

  # Generates, once, the console host key and the registry's client key on
  # this machine, then (re)writes each network's sshd fragment and the pinned
  # known_hosts. Nothing secret enters the repository or the Nix store.
  consoleSetup = pkgs.writeShellScript "nebula-registry-console-setup" ''
    set -euo pipefail
    keygen=${lib.getExe' pkgs.openssh "ssh-keygen"}
    install -d -m 0750 -o root -g nebula-console ${consoleDir}
    install -d -m 0750 -o nebula-registry -g nebula-registry ${stateDir}
    if [ ! -e ${consoleDir}/host_key ]; then
      "$keygen" -q -t ed25519 -N "" -C nebula-console -f ${consoleDir}/host_key
    fi
    chown root:nebula-console ${consoleDir}/host_key ${consoleDir}/host_key.pub
    chmod 0640 ${consoleDir}/host_key
    if [ ! -e ${stateDir}/client_key ]; then
      "$keygen" -q -t ed25519 -N "" -C nebula-registry -f ${stateDir}/client_key
    fi
    chown nebula-registry:nebula-registry ${stateDir}/client_key ${stateDir}/client_key.pub
    chmod 0600 ${stateDir}/client_key

    client_key=$(cat ${stateDir}/client_key.pub)
    read -r host_type host_key _ < ${consoleDir}/host_key.pub
    known_hosts=$(mktemp)
    ${lib.concatMapStrings (name: ''
      printf '{"sshd":{"enabled":true,"listen":"127.0.0.1:%s","host_key":"%s","authorized_users":[{"user":"%s","keys":["%s"]}]}}\n' \
        ${toString cfg.networks.${name}.consolePort} ${consoleDir}/host_key ${consoleUser} "$client_key" \
        > ${consoleDir}/${name}.yml
      chown root:nebula-console ${consoleDir}/${name}.yml
      chmod 0640 ${consoleDir}/${name}.yml
      printf '[127.0.0.1]:%s %s %s\n' ${
        toString cfg.networks.${name}.consolePort
      } "$host_type" "$host_key" >> "$known_hosts"
    '') names}
    install -m 0644 -o nebula-registry -g nebula-registry "$known_hosts" ${stateDir}/known_hosts
    rm -f "$known_hosts"
  '';
in
{
  options.dev.johnrinehart.nebula.registry = {
    enable = lib.mkEnableOption ''
      the Nebula lighthouse peer registry: permanent peer history, liveness,
      per-VPN DNS and an HTTPS peer view scoped to each caller's certificate
    '';
    parentDomain = lib.mkOption {
      type = lib.types.str;
      description = "Each VPN is served as the zone `<network>.<parentDomain>`.";
    };
    siteLabel = lib.mkOption {
      type = lib.types.str;
      default = "lighthouse";
      description = "The HTTPS site is `<siteLabel>.<network>.<parentDomain>` on each VPN.";
    };
    networks = lib.mkOption {
      default = { };
      description = "Local lighthouse instances (`services.nebula.networks`) to register.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            address = lib.mkOption {
              type = lib.types.str;
              example = "10.77.0.1";
              description = "This lighthouse's overlay address on the network (from its certificate).";
            };
            consolePort = lib.mkOption {
              type = lib.types.port;
              example = 2222;
              description = "Localhost port for this network's Nebula debug console.";
            };
            aliases = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Additional private DNS zones served by this registry.";
            };
          };
        }
      );
    };
    tls.extraCertificates = lib.mkOption {
      default = { };
      description = "Runtime TLS certificates selected by HTTPS SNI hostname.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            certFile = lib.mkOption {
              type = lib.types.str;
              description = "Path to the server certificate for this hostname.";
            };
            keyFile = lib.mkOption {
              type = lib.types.str;
              description = "Path to the private TLS key for this hostname.";
            };
          };
        }
      );
    };
    acme = {
      dnsProvider = lib.mkOption {
        type = lib.types.str;
        description = "lego DNS provider for the DNS-01 challenge.";
      };
      environmentFile = lib.mkOption {
        type = lib.types.str;
        description = ''
          Provider credentials (e.g. `CF_DNS_API_TOKEN=…`), placed on the host
          out of band. Until it exists the site serves a self-signed
          placeholder and ordering is skipped.
        '';
      };
    };
    pollInterval = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Seconds between console polls.";
    };
    offlineAfterPolls = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Missed polls before a peer is marked offline.";
    };
    eventRetentionDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 365;
      description = "Days of events to keep; peers are kept forever.";
    };
    upstreamResolvers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "1.1.1.1"
        "9.9.9.9"
      ];
      description = ''
        IP addresses of resolvers that receive queries outside the overlay
        zones, tried in order. Clients without split DNS (e.g. Mobile Nebula
        without match domains) send every lookup to the lighthouse, so
        without forwarding only overlay names resolve for them. Empty means
        other names are refused.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && names != [ ]) (
    lib.mkMerge [
      {
        assertions = lib.concatMap (name: [
          {
            assertion = config.services.nebula.networks.${name}.isLighthouse or false;
            message = "nebula registry: services.nebula.networks.${name} must be an enabled lighthouse.";
          }
          {
            assertion = config.environment.etc ? "nebula/${name}.yml";
            message = "nebula registry: network ${name} must use /etc/nebula/${name}.yml (stateVersion >= 25.11 or enableReload).";
          }
        ]) names;

        users.users.nebula-registry = {
          isSystemUser = true;
          group = "nebula-registry";
          home = stateDir;
        };
        users.groups.nebula-registry = { };
        users.groups.nebula-console = { };

        systemd.services.nebula-registry-console = {
          description = "Prepare Nebula debug consoles for the peer registry";
          requiredBy = map (name: "nebula@${name}.service") names;
          before = map (name: "nebula@${name}.service") names;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = consoleSetup;
          };
        };

        security.acme = {
          acceptTerms = true;
          certs.${certName} = {
            extraDomainNames = lib.tail sites;
            inherit (cfg.acme) dnsProvider environmentFile;
            group = "nebula-registry";
            reloadServices = [ "nebula-registry.service" ];
          };
        };
        # Without credentials the order would fail; the placeholder
        # certificate keeps the site up until they are installed.
        systemd.services."acme-order-renew-${certName}".unitConfig.ConditionPathExists =
          cfg.acme.environmentFile;

        systemd.services.nebula-registry = {
          description = "Nebula peer registry";
          wantedBy = [ "multi-user.target" ];
          requires = [ "nebula-registry-console.service" ];
          wants = [ "acme-${certName}.service" ];
          after = [
            "nebula-registry-console.service"
            "acme-${certName}.service"
          ]
          ++ map (name: "nebula@${name}.service") names;
          environment.HOME = stateDir;
          serviceConfig = {
            ExecStart = "${lib.getExe package} --config ${registryConfig}";
            User = "nebula-registry";
            Group = "nebula-registry";
            StateDirectory = "nebula-registry";
            StateDirectoryMode = "0750";
            AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
            CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            Restart = "always";
            RestartSec = "5s";
          };
        };
      }
      {
        # Run each lighthouse from a config directory: the NixOS-generated file
        # plus the host-generated console fragment (its authorized key cannot
        # be known at evaluation time).
        environment.etc = lib.mkMerge (
          map (name: {
            "nebula/${name}.d/00-nixos.yml".source = config.environment.etc."nebula/${name}.yml".source;
            "nebula/${name}.d/50-registry-console.yml".source = "${consoleDir}/${name}.yml";
          }) names
        );
        users.users = lib.mkMerge (
          map (name: { "nebula-${name}".extraGroups = [ "nebula-console" ]; }) names
        );
        systemd.services = lib.mkMerge (
          map (name: {
            "nebula@${name}" = {
              restartTriggers = [ consoleSetup ];
              serviceConfig.ExecStart = lib.mkForce "${
                lib.getExe' config.services.nebula.networks.${name}.package "nebula"
              } -config /etc/nebula/${name}.d";
            };
          }) names
        );
        networking.firewall.interfaces = lib.mkMerge (
          map (name: {
            ${device name} = {
              allowedUDPPorts = [ 53 ];
              allowedTCPPorts = [
                53
                443
              ];
            };
          }) names
        );
      }
    ]
  );
}
