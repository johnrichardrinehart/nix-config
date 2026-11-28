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

  stateFileList = lib.mapAttrsToList (name: file: {
    inherit name;
    inherit (file)
      path
      content
      mode
      ;
  }) cfg.stateFiles;
  stateManifest = jsonFormat.generate "uz801-state-manifest.json" stateFileList;
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

    stateManifest = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = stateManifest;
      description = ''
        Host-side JSON manifest listing non-secret per-node files installed onto
        /state by `uz801-deploy` so multiple devices share an identical image hash.
      '';
    };

    stateFiles = lib.mkOption {
      default = { };
      description = "Per-node non-secret files installed onto /state by uz801-deploy.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            path = lib.mkOption {
              type = lib.types.str;
              description = "Destination path under /state on the target device.";
            };

            content = lib.mkOption {
              type = lib.types.str;
              description = "Exact text contents written to path.";
            };

            mode = lib.mkOption {
              type = lib.types.str;
              default = "0644";
              description = "Octal permission mode applied to the installed file.";
            };
          };
        }
      );
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
