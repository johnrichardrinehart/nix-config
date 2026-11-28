{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sops;
  secretList = lib.mapAttrsToList (name: secret: {
    inherit name;
    sopsFile = "${secret.sopsFile}";
    inherit (secret)
      key
      path
      mode
      optional
      ;
  }) cfg.secrets;

  jsonFormat = pkgs.buildPackages.formats.json { };
  deployManifest = jsonFormat.generate "uz801-sops-manifest.json" secretList;
in
{
  options.sops = {
    defaultSopsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Default SOPS-encrypted YAML file for secrets without an explicit sopsFile.";
    };

    deployManifest = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = deployManifest;
      description = ''
        Host-side JSON manifest listing every declared secret and its SOPS source
        file. Consumed by `uz801-deploy` on the deploying host so `sops` never
        needs to be installed on the target device.
      '';
    };

    secrets = lib.mkOption {
      default = { };
      description = "Secrets decrypted on the deploying host and installed onto /state/secrets.";
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
                default = "/state/secrets/${name}";
                description = "Destination path on the target device for the decrypted secret.";
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
}
