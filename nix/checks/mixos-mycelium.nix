{
  inputs,
  lib,
  pkgs,
}:
let
  cfg0 = inputs.self.mixosConfigurations.uz801-0.config;
  cfg1 = inputs.self.mixosConfigurations.uz801-1.config;
  nebulaCfg = cfg0.etc."nebula/config.yml".source;
  nebulaRun = cfg0.services.nebula.run;
  lhCfg = cfg0.etc."nebula/lighthouse.yml".source;
  lhRun = cfg0.services.nebula-lighthouse.run;
  regCfg = cfg0.etc."nebula/registry.json".source;
  regRun = cfg0.services.nebula-registry.run;
  ddnsRun = cfg0.services.cloudflare-ddns.run;
  caBundle = cfg0.etc."ssl/certs/ca-certificates.crt".source;
  hostNameFile = cfg0.etc."hostname".source;
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
  cfg0.system.build.slotImage == cfg1.system.build.slotImage
) "uz801-0 and uz801-1 must evaluate to the exact same slotImage store path!";
assert lib.assertMsg (
  cfg0.uz801.hostName == "uz801"
) "shared fleet hostName mismatch: ${cfg0.uz801.hostName}";
assert lib.assertMsg (
  cfg0.system.build.slotImage.name == "uz801-wifi.img"
) "shared fleet slotImage name mismatch: ${cfg0.system.build.slotImage.name}";
pkgs.runCommand "mixos-mycelium-check" { } ''
  # Shared fleet image checks (identical for uz801-0 and uz801-1)
  grep -q '^uz801$' ${hostNameFile}
  grep -q 'nebula.mycelium' ${nebulaCfg}
  grep -q 'am_lighthouse: false' ${nebulaCfg}
  grep -q 'port: 0' ${nebulaCfg}
  grep -q 'nebula-lighthouse.johnrinehart.dev:4242' ${nebulaCfg}
  grep -q 'uz801-0.nebula.johnrinehart.dev:4242' ${nebulaCfg}
  grep -q 'uz801-1.nebula.johnrinehart.dev:4243' ${nebulaCfg}
  grep -q '/state/secrets/nebula-ca' ${nebulaCfg}
  grep -q '/state/secrets/nebula-cert' ${nebulaCfg}
  grep -q '/state/secrets/nebula-key' ${nebulaCfg}
  ${lib.concatMapStringsSep "\n" (fp: "grep -q ${lib.escapeShellArg fp} ${nebulaCfg}") blocklist}

  # Verify runtime self-loopback rewrite works for both uz801-0 and uz801-1
  awk -v ip="10.77.0.10" -v ep="127.0.0.1:4242" '
    $0 ~ "^  " ip ":$" || $0 ~ "^  \"" ip "\":$" { hit=1; print; next }
    hit && $0 ~ "^  - " { print "  - " ep; hit=0; next }
    hit && $0 ~ "^    - " { print "    - " ep; hit=0; next }
    { hit=0; print }
  ' ${nebulaCfg} > rew0.yml
  grep -q '127.0.0.1:4242' rew0.yml
  grep -q 'uz801-1.nebula.johnrinehart.dev:4243' rew0.yml

  awk -v ip="10.77.0.12" -v ep="127.0.0.1:4243" '
    $0 ~ "^  " ip ":$" || $0 ~ "^  \"" ip "\":$" { hit=1; print; next }
    hit && $0 ~ "^  - " { print "  - " ep; hit=0; next }
    hit && $0 ~ "^    - " { print "    - " ep; hit=0; next }
    { hit=0; print }
  ' ${nebulaCfg} > rew1.yml
  grep -q '127.0.0.1:4243' rew1.yml
  grep -q 'uz801-0.nebula.johnrinehart.dev:4242' rew1.yml

  # No sops binary on-device; nebula package is stripped cmd/nebula-only (no nebula-cert)
  test ! -e ${cfg0.dev.johnrinehart.mycelium.package}/bin/nebula-cert
  grep -q 'nebula-ca' ${cfg0.sops.deployManifest}
  grep -q 'cloudflare-api-token' ${cfg0.sops.deployManifest}
  grep -q 'uz801-0' ${cfg0.sops.stateManifest}
  grep -q '10.77.0.10' ${cfg0.sops.stateManifest}
  grep -q 'uz801-1' ${cfg1.sops.stateManifest}
  grep -q '10.77.0.12' ${cfg1.sops.stateManifest}
  grep -q '4243' ${cfg1.sops.stateManifest}

  # Key-only SSH on LAN/USB, trusted Nebula peer SSH on nebula.mycelium,
  # 6-bit LED mask, syntax checks, and zero bash in the shared closure
  grep -q 'port: .*2222' ${nebulaCfg}
  grep -q 'port: .*8022' ${nebulaCfg}
  grep -q -- '-N nebula.mycelium' ${cfg0.services.dropbear.run}
  grep -q 'rp_filter' ${nebulaRun}
  sh -n ${nebulaRun}
  sh -n ${lhRun}
  sh -n ${regRun}
  sh -n ${ddnsRun}
  sh -n ${cfg0.services.dropbear.run}
  sh -n ${cfg0.services.uz801-led.run}
  for chk in wifi nebula lighthouse registry ddns system; do
    grep -q "''${chk}:" ${cfg0.services.uz801-led.run}
  done
  ! grep -iq 'bash' ${cfg0.system.build.manifest}

  # Separate strict lighthouse+relay instance (runtime port from /state/nebula/identity.env)
  head -n 1 ${lhRun} | grep -qx '#!/bin/sh'
  grep -q '/run/nebula-lighthouse.d' ${lhRun}
  grep -q '/state/nebula/identity.env' ${lhRun}
  grep -q 'metric 200' ${lhRun}
  grep -q 'am_lighthouse: true' ${lhCfg}
  grep -q 'am_relay: true' ${lhCfg}
  grep -q 'use_relays: false' ${lhCfg}
  grep -q 'disabled: false' ${lhCfg}
  grep -q 'dev: nebula.lh' ${lhCfg}
  grep -q "port: '443'" ${lhCfg} || grep -q 'port: "443"' ${lhCfg}
  grep -q "port: '53'" ${lhCfg} || grep -q 'port: "53"' ${lhCfg}
  grep -q 'outbound: \[\]' ${lhCfg}
  ${lib.concatMapStringsSep "\n" (fp: "grep -q ${lib.escapeShellArg fp} ${lhCfg}") blocklist}

  # C nebula-registry dashboard + DNS with runtime identity template
  head -n 1 ${regRun} | grep -qx '#!/bin/sh'
  grep -q '/state/nebula/identity.env' ${regRun}
  grep -q '"__LH_ADDRESS__"' ${regCfg}
  grep -q '"__LH_SITE__"' ${regCfg}
  grep -q '"nebula.lh"' ${regCfg}
  grep -q '"dnsPort":53' ${regCfg} || grep -q '"dnsPort": 53' ${regCfg}
  grep -q '"localDnsPort":53' ${regCfg} || grep -q '"localDnsPort": 53' ${regCfg}
  grep -q '"10.77.0.10"' ${regCfg}
  grep -q '"10.77.0.12"' ${regCfg}
  grep -q '"/state/secrets/nebula-registry-tls-cert"' ${regCfg}
  grep -q '"/state/secrets/nebula-registry-tls-key"' ${regCfg}
  grep -q '"/sbin/dbclient"' ${regCfg}

  # Cloudflare DDNS service wired for runtime /state/cloudflare-ddns.env + SOPS token
  head -n 1 ${ddnsRun} | grep -qx '#!/bin/sh'
  grep -q 'uz801-cf-ddns' ${ddnsRun}
  grep -q '/state/secrets/cloudflare-api-token' ${ddnsRun}
  grep -q 'ip -4 -o addr show' ${ddnsRun}

  # Mycelium TLS CA appended to system CA bundle
  ca_line=$(grep -v '^-----' ${tlsCa} | head -n 1)
  grep -Fq "$ca_line" ${caBundle}

  # Standalone single-instance strict lighthouse role still works
  grep -q 'am_lighthouse: true' ${standaloneLhCfg}
  grep -q 'am_relay: false' ${standaloneLhCfg}
  grep -q 'outbound: \[\]' ${standaloneLhCfg}

  touch "$out"
''
