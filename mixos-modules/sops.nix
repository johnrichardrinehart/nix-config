{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sops;
  secretList = lib.attrValues cfg.secrets;
  sopsBin = "${lib.getBin cfg.package}/bin/sops";

  extractScript = pkgs.writeScriptBin "uz801-sops-install" ''
    #!/bin/sh
    # Decrypt declared SOPS secrets into /run/secrets (tmpfs) using the device's
    # persistent age private key on /state. Plaintext secrets stay in RAM only.
    set -eu

    KEY_FILE=${lib.escapeShellArg cfg.age.keyFile}
    if [ ! -r "$KEY_FILE" ]; then
      printf 'uz801-sops: missing age key %s; skipping secret decryption\n' "$KEY_FILE" >&2
      exit 0
    fi

    umask 077
    mkdir -p /run/secrets
    chmod 0700 /run/secrets

    export SOPS_AGE_KEY_FILE="$KEY_FILE"
    ${lib.concatMapStringsSep "\n" (
      secret:
      let
        dir = builtins.dirOf secret.path;
        extractArg = ''["${secret.key}"]'';
      in
      ''
        mkdir -p ${lib.escapeShellArg dir}
        if ${sopsBin} -d --extract ${lib.escapeShellArg extractArg} "${secret.sopsFile}" > ${lib.escapeShellArg "${secret.path}.tmp"} 2>/dev/null; then
          chmod ${lib.escapeShellArg secret.mode} ${lib.escapeShellArg "${secret.path}.tmp"}
          mv -f ${lib.escapeShellArg "${secret.path}.tmp"} ${lib.escapeShellArg secret.path}
        else
          rm -f ${lib.escapeShellArg "${secret.path}.tmp"}
          ${
            if secret.optional then
              ''printf 'uz801-sops: optional secret %s not found in %s; skipping\n' ${lib.escapeShellArg secret.key} ${lib.escapeShellArg (baseNameOf (toString secret.sopsFile))} >&2''
            else
              ''
                printf 'uz801-sops: failed to decrypt secret %s from %s\n' ${lib.escapeShellArg secret.key} ${lib.escapeShellArg (baseNameOf (toString secret.sopsFile))} >&2
                exit 1
              ''
          }
        fi
      ''
    ) secretList}
  '';
in
{
  options.sops = {
    defaultSopsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Default SOPS-encrypted YAML file for secrets without an explicit sopsFile.";
    };

    age.keyFile = lib.mkOption {
      type = lib.types.str;
      default = "/state/sops/age-key.txt";
      description = "On-device path to the persistent age private key file.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.sops;
      defaultText = lib.literalExpression "pkgs.sops";
      description = "SOPS package used to decrypt secrets at boot.";
    };

    secrets = lib.mkOption {
      default = { };
      description = "Secrets decrypted from SOPS files into /run/secrets at boot.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              sopsFile = lib.mkOption {
                type = lib.types.path;
                default = cfg.defaultSopsFile;
                description = "SOPS-encrypted YAML file containing this secret.";
              };

              key = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = "Top-level YAML key to extract from sopsFile.";
              };

              path = lib.mkOption {
                type = lib.types.str;
                default = "/run/secrets/${name}";
                description = "Destination path in tmpfs for the decrypted secret.";
              };

              mode = lib.mkOption {
                type = lib.types.str;
                default = "0400";
                description = "Octal permission mode applied to the decrypted file.";
              };

              optional = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Continue without failing if the key is absent from sopsFile.";
              };
            };
          }
        )
      );
    };
  };

  config = lib.mkIf (cfg.secrets != { }) {
    packages = [
      (lib.getBin cfg.package)
      extractScript
    ];

    init.uz801-sops = {
      action = "once";
      process = "${extractScript}/bin/uz801-sops-install";
    };
  };
}
