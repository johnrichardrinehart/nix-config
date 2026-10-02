{
  inputs,
  lib,
  pkgs,
}:
let
  credentials = {
    ca = "/run/nebula/ca.crt";
    cert = "/run/nebula/host.crt";
    key = "/run/nebula/host.key";
  };
  canonicalCA = ../../nixos-modules/nebula/mycelium/mycelium-tls-ca.crt;
  publicCA = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  evaluate =
    extra:
    (lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ../../nixos-modules/nebula
        {
          nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
          system.stateVersion = "26.05";
        }
        extra
      ];
    }).config;
  peer = evaluate {
    dev.johnrinehart.mycelium = credentials // {
      enable = true;
    };
  };
  customPeer = evaluate {
    dev.johnrinehart.mycelium = credentials // {
      enable = true;
      peerGroup = "workstation";
      lighthouse.address = "10.88.0.1";
      firewall = {
        inbound = [
          {
            proto = "udp";
            port = "5353";
          }
          {
            proto = "tcp";
            port = "8080";
          }
        ];
        peerSshPorts = [
          "22"
          "2222"
          "8022"
        ];
        allowPeerHTTPS = true;
      };
    };
  };
  lighthouse = evaluate {
    dev.johnrinehart.mycelium = credentials // {
      enable = true;
      role = "lighthouse";
    };
  };
  disabled = evaluate { };
  optedOut = evaluate {
    dev.johnrinehart.mycelium = credentials // {
      enable = true;
      trustCA.enable = false;
    };
  };
  replacedCA = evaluate {
    dev.johnrinehart.mycelium = credentials // {
      enable = true;
      trustCA.bundle = publicCA;
    };
  };
  independentCA = evaluate {
    dev.johnrinehart.mycelium = credentials // {
      enable = true;
      trustCA.bundle = publicCA;
    };
    security.pki.certificateFiles = [ canonicalCA ];
  };
  generic = evaluate {
    dev.johnrinehart.nebula.networks = {
      alpha.dns = {
        enable = true;
        server = "10.31.0.1";
        domains = [
          "alpha.internal"
          "alpha.example"
        ];
      };
      beta.dns = {
        enable = true;
        server = "10.32.0.1";
        domains = [ "beta.internal" ];
      };
    };
    services.nebula.networks = lib.genAttrs [ "alpha" "beta" ] (
      name:
      credentials
      // {
        tun.device = "vpn-${name}";
        firewall = {
          inbound = [
            {
              proto = "udp";
              port = "123";
              host = "any";
            }
          ];
          outbound = [
            {
              proto = "tcp";
              port = "8443";
              host = "any";
            }
          ];
        };
      }
    );
  };
  firewall = config: config.services.nebula.networks.mycelium.firewall;
  bundle = config: config.environment.etc."ssl/certs/ca-certificates.crt".source;
  cases = pkgs.writeText "mycelium-cases.json" (
    builtins.toJSON {
      peer = firewall peer;
      customPeer = firewall customPeer;
      lighthouse = firewall lighthouse;
      generic = lib.genAttrs [ "alpha" "beta" ] (name: {
        firewall = generic.services.nebula.networks.${name}.firewall;
        commands = generic.systemd.services."nebula@${name}".serviceConfig.ExecStartPost;
        blocklist = generic.services.nebula.networks.${name}.settings.pki.blocklist or [ ];
      });
    }
  );
in
assert lib.assertMsg generic.services.resolved.enable "generic DNS requires resolved";
pkgs.runCommand "mycelium-module"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.openssl
    ];
  }
  ''
    python3 - ${cases} <<'PY'
    import ipaddress
    import itertools
    import json
    import shlex
    import sys

    cases = json.load(open(sys.argv[1]))

    def allowed(rules, identity, proto, port):
        address, groups = identity
        for rule in rules:
            if rule['proto'] not in ('any', proto):
                continue
            value = str(rule['port'])
            if value != 'any':
                bounds = value.split('-')
                if not (int(bounds[0]) <= port <= int(bounds[-1])):
                    continue
            selectors = []
            if rule.get('host'):
                selectors.append(rule['host'] == 'any')
            if rule.get('group'):
                selectors.append(rule['group'] in groups)
            if rule.get('groups'):
                selectors.append(set(rule['groups']).issubset(groups))
            if rule.get('cidr'):
                selectors.append(ipaddress.ip_address(address) in ipaddress.ip_network(rule['cidr']))
            if any(selectors):
                return True
        return False

    identities = {
        'peer': ('10.77.0.2', {'peer'}),
        'workstation': ('10.88.0.2', {'workstation'}),
        'lighthouse': ('10.77.0.1', set()),
        'custom-lighthouse': ('10.88.0.1', set()),
        'stranger': ('10.77.0.3', set()),
    }
    ports = [0, 22, 23, 53, 80, 123, 443, 444, 2222, 5353, 8022, 8080, 8443, 65535]

    def check_policy(label, policy, expected):
        test_ports = set(ports)
        for rules in policy.values():
            for rule in rules:
                if str(rule['port']) != 'any':
                    for bound in str(rule['port']).split('-'):
                        test_ports.update(p for p in (int(bound) - 1, int(bound), int(bound) + 1) if 0 <= p <= 65535)
        for direction, identity, proto, port in itertools.product(
            ('inbound', 'outbound'), identities, ('icmp', 'tcp', 'udp'), sorted(test_ports)
        ):
            actual = allowed(policy[direction], identities[identity], proto, port)
            want = expected(direction, identity, proto, port)
            assert actual == want, f'{label}: {direction} {identity} {proto}/{port}: {actual} != {want}'

    def peer_policy(direction, identity, proto, port, *, custom=False):
        group = 'workstation' if custom else 'peer'
        lighthouse = 'custom-lighthouse' if custom else 'lighthouse'
        if direction == 'inbound':
            paths = [('udp', 5353), ('tcp', 8080)] if custom else [('tcp', 22)]
            return identity == group and ((not custom and proto == 'icmp') or (proto, port) in paths)
        if identity == lighthouse:
            return proto == 'icmp' or (proto, port) in [('tcp', 22), ('udp', 53), ('tcp', 53), ('tcp', 443)]
        ports = [22, 2222, 8022, 443] if custom else [22]
        return identity == group and (proto == 'icmp' or (proto == 'tcp' and port in ports))

    check_policy('peer', cases['peer'], peer_policy)
    check_policy('custom peer', cases['customPeer'], lambda *args: peer_policy(*args, custom=True))
    check_policy('lighthouse', cases['lighthouse'], lambda direction, identity, proto, port:
        direction == 'inbound' and identity == 'peer' and
        (proto == 'icmp' or (proto, port) in [('tcp', 22), ('udp', 53), ('tcp', 53), ('tcp', 443)]))

    routes = {}
    for name, network in cases['generic'].items():
        assert network['blocklist'] == [], f'generic {name}: injected revocations'
        check_policy(f'generic {name}', network['firewall'], lambda direction, identity, proto, port:
            (proto, port) == (('udp', 123) if direction == 'inbound' else ('tcp', 8443)))
        for command in network['commands']:
            executable, operation, device, *args = shlex.split(command)
            assert executable.startswith('+') and executable.endswith('/bin/resolvectl'), 'DNS privilege'
            state = routes.setdefault(device, {})
            assert operation not in state, 'duplicate DNS operation'
            state[operation] = args
    assert routes == {
        'vpn-alpha': {'dns': ['10.31.0.1'], 'domain': ['~alpha.internal', '~alpha.example'], 'default-route': ['false']},
        'vpn-beta': {'dns': ['10.32.0.1'], 'domain': ['~beta.internal'], 'default-route': ['false']},
    }, 'isolated DNS routes'
    PY

    verify_ca() {
      openssl verify -no_check_time -no-CApath -no-CAstore -CAfile "$1" ${canonicalCA}
    }
    verify_ca ${bundle peer}
    verify_ca ${bundle independentCA}
    for bundle in ${bundle disabled} ${bundle optedOut} ${bundle replacedCA} ${bundle generic}; do
      if verify_ca "$bundle"; then
        echo 'Unexpected Mycelium CA trust' >&2
        exit 1
      fi
    done
    touch "$out"
  ''
