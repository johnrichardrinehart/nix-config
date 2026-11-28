{
  inputs,
  lib,
  pkgs,
}:
let
  cfg = inputs.self.mixosConfigurations.uz801-0.config;
  nebulaCfg = cfg.etc."nebula/config.yml".source;
  lhCfg = cfg.etc."nebula/lighthouse.yml".source;
  lhRun = cfg.services.nebula-lighthouse.run;
  regCfg = cfg.etc."nebula/registry.json".source;
  regRun = cfg.services.nebula-registry.run;
  ddnsRun = cfg.services.cloudflare-ddns.run;
  caBundle = cfg.etc."ssl/certs/ca-certificates.crt".source;
  hostNameFile = cfg.etc."hostname".source;
  blocklist = import ../../nixos-modules/nebula/mycelium/blocklist.nix;
  tlsCa = ../../nixos-modules/nebula/mycelium/mycelium-tls-ca.crt;

  standaloneLhEval = inputs.nixos-uz801.lib.uz801System {
    buildSystem = pkgs.stdenv.hostPlatform.system;
    modules = [
      inputs.self.mixosModules.mycelium
      {
        uz801.hostName = "uz801-lh-only-test";
        dev.johnrinehart.mycelium = {
          enable = true;
          role = "lighthouse";
          relay.enable = false;
        };
      }
    ];
  };
  standaloneLhCfg = standaloneLhEval.config.etc."nebula/config.yml".source;
in
assert lib.assertMsg (
  cfg.uz801.hostName == "uz801-0"
) "uz801-0 hostName mismatch: ${cfg.uz801.hostName}";
assert lib.assertMsg (
  cfg.system.build.slotImage.name == "uz801-0-wifi.img"
) "uz801-0 slotImage name mismatch: ${cfg.system.build.slotImage.name}";
pkgs.runCommand "mixos-mycelium-check" { } ''
  # uz801-0 peer instance (10.77.0.11/24, TUN enabled, dual lighthouses, SOPS)
  grep -q '^uz801-0$' ${hostNameFile}
  grep -q 'nebula.mycelium' ${nebulaCfg}
  grep -q 'am_lighthouse: false' ${nebulaCfg}
  grep -q 'port: 0' ${nebulaCfg}
  grep -q 'nebula-lighthouse.johnrinehart.dev:4242' ${nebulaCfg}
  grep -q '127.0.0.1:4242' ${nebulaCfg}
  grep -q "port: '443'" ${nebulaCfg} || grep -q 'port: "443"' ${nebulaCfg}
  grep -q '/state/secrets/nebula-ca' ${nebulaCfg}
  grep -q '/state/secrets/nebula-cert' ${nebulaCfg}
  grep -q '/state/secrets/nebula-key' ${nebulaCfg}
  ${lib.concatMapStringsSep "\n" (fp: "grep -q ${lib.escapeShellArg fp} ${nebulaCfg}") blocklist}

  # No sops binary on-device; nebula package is stripped cmd/nebula-only (no nebula-cert)
  test ! -e ${cfg.uz801.nebula.package}/bin/nebula-cert
  grep -q 'nebula-ca' ${cfg.sops.deployManifest}
  grep -q 'cloudflare-api-token' ${cfg.sops.deployManifest}

  # uz801-0 separate headless lighthouse+relay instance (10.77.0.10/24, tun.disabled=true)
  head -n 1 ${lhRun} | grep -qx '#!/bin/sh'
  grep -q '/run/nebula-lighthouse.d' ${lhRun}
  grep -q 'am_lighthouse: true' ${lhCfg}
  grep -q 'am_relay: true' ${lhCfg}
  grep -q 'use_relays: false' ${lhCfg}
  grep -q 'disabled: true' ${lhCfg}
  grep -q 'port: 4242' ${lhCfg}
  grep -q 'inbound: \[\]' ${lhCfg}
  grep -q 'outbound: \[\]' ${lhCfg}
  grep -q '/state/secrets/nebula-ca' ${lhCfg}
  grep -q '/state/secrets/nebula-lighthouse-cert' ${lhCfg}
  grep -q '/state/secrets/nebula-lighthouse-key' ${lhCfg}
  ${lib.concatMapStringsSep "\n" (fp: "grep -q ${lib.escapeShellArg fp} ${lhCfg}") blocklist}

  # uz801-0 C nebula-registry dashboard bound on peer TUN 10.77.0.11:443
  head -n 1 ${regRun} | grep -qx '#!/bin/sh'
  grep -q 'nebula-registry --config /etc/nebula/registry.json' ${regRun}
  grep -q '"10.77.0.11"' ${regCfg}
  grep -q '"uz801-0.mycelium.internal"' ${regCfg}
  grep -q '"/sbin/dbclient"' ${regCfg}

  # Cloudflare DDNS service wired for host-deployed SOPS token + valid shebang + network-change polling
  head -n 1 ${ddnsRun} | grep -qx '#!/bin/sh'
  grep -q 'uz801-cf-ddns' ${ddnsRun}
  grep -q '/state/secrets/cloudflare-api-token' ${ddnsRun}
  grep -q 'ip -4 -o addr show' ${ddnsRun}
  grep -q 'uz801-0.nebula.johnrinehart.dev' $(grep -o '/nix/store/[^ ]*-uz801-cf-ddns' ${ddnsRun} | head -n 1)/bin/uz801-cf-ddns

  # Mycelium TLS CA appended to system CA bundle
  ca_line=$(grep -v '^-----' ${tlsCa} | head -n 1)
  grep -Fq "$ca_line" ${caBundle}

  # Standalone single-instance strict lighthouse role still works
  grep -q 'am_lighthouse: true' ${standaloneLhCfg}
  grep -q 'am_relay: false' ${standaloneLhCfg}
  grep -q 'outbound: \[\]' ${standaloneLhCfg}

  touch "$out"
''
