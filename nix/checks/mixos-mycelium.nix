{
  inputs,
  lib,
  pkgs,
}:
let
  cfg = inputs.self.mixosConfigurations.uz801-0.config;
  nebulaCfg = cfg.etc."nebula/config.yml".source;
  nebulaRun = cfg.services.nebula.run;
  ddnsRun = cfg.services.cloudflare-ddns.run;
  caBundle = cfg.etc."ssl/certs/ca-certificates.crt".source;
  hostNameFile = cfg.etc."hostname".source;
  blocklist = import ../../nixos-modules/nebula/mycelium/blocklist.nix;
  tlsCa = ../../nixos-modules/nebula/mycelium/mycelium-tls-ca.crt;

  peerEval = inputs.nixos-uz801.lib.uz801System {
    buildSystem = pkgs.stdenv.hostPlatform.system;
    modules = [
      inputs.self.mixosModules.mycelium
      {
        uz801.hostName = "uz801-peer-test";
        dev.johnrinehart.mycelium = {
          enable = true;
          extraLighthouses = [
            {
              address = "10.77.0.10";
              endpoint = "uz801-0.example:4242";
            }
          ];
        };
      }
    ];
  };
  peerNebulaCfg = peerEval.config.etc."nebula/config.yml".source;
in
assert lib.assertMsg (
  cfg.uz801.hostName == "uz801-0"
) "uz801-0 hostName mismatch: ${cfg.uz801.hostName}";
assert lib.assertMsg (
  cfg.system.build.slotImage.name == "uz801-0-wifi.img"
) "uz801-0 slotImage name mismatch: ${cfg.system.build.slotImage.name}";
pkgs.runCommand "mixos-mycelium-check" { } ''
  # uz801-0 strict lighthouse + relay (empty outbound, cert guard, SOPS secrets)
  grep -q '^uz801-0$' ${hostNameFile}
  grep -q 'nebula.mycelium' ${nebulaCfg}
  grep -q 'am_lighthouse: true' ${nebulaCfg}
  grep -q 'am_relay: true' ${nebulaCfg}
  grep -q 'use_relays: false' ${nebulaCfg}
  grep -q 'port: 4242' ${nebulaCfg}
  grep -q 'outbound: \[\]' ${nebulaCfg}
  grep -q '/run/secrets/nebula-ca' ${nebulaCfg}
  grep -q '/run/secrets/nebula-cert' ${nebulaCfg}
  grep -q '/run/secrets/nebula-key' ${nebulaCfg}
  grep -q 'nebula-cert print -json' ${nebulaRun}
  ${lib.concatMapStringsSep "\n" (fp: "grep -q ${lib.escapeShellArg fp} ${nebulaCfg}") blocklist}

  # Cloudflare DDNS service wired for SOPS token + startup + network-change triggers
  grep -q 'uz801-cf-ddns' ${ddnsRun}
  grep -q '/run/secrets/cloudflare-api-token' ${ddnsRun}
  grep -q 'ip -4 monitor address route' ${ddnsRun}
  grep -q 'uz801-0.nebula.johnrinehart.dev' ${cfg.services.cloudflare-ddns.run} || grep -q 'uz801-0.nebula.johnrinehart.dev' $(grep -o '/nix/store/[^ ]*-uz801-cf-ddns' ${ddnsRun} | head -n 1)/bin/uz801-cf-ddns

  # Mycelium TLS CA appended to system CA bundle
  ca_line=$(grep -v '^-----' ${tlsCa} | head -n 1)
  grep -Fq "$ca_line" ${caBundle}

  # Peer MixOS config with secondary lighthouse
  grep -q 'am_lighthouse: false' ${peerNebulaCfg}
  grep -q 'nebula-lighthouse.johnrinehart.dev:4242' ${peerNebulaCfg}
  grep -q 'uz801-0.example:4242' ${peerNebulaCfg}
  grep -q '10.77.0.10' ${peerNebulaCfg}

  touch "$out"
''
