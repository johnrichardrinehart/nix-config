{ pkgs, ... }:
{
  projectRootFile = "flake.nix";

  # SOPS writes these files (.sops.yaml creation_rules). A formatter must not
  # change them: the MAC covers the values, and ciphertext scalars are long.
  settings.global.excludes = [ "secrets/*.yaml" ];

  settings.formatter = {
    markdownlint = {
      command = "${pkgs.markdownlint-cli}/bin/markdownlint";
      includes = [ "*.md" ];
      options = [
        "--disable"
        "MD013"
        "MD040"
        "MD060"
      ];
    };
  };

  programs = {
    actionlint.enable = true;
    deadnix.enable = true;
    nixfmt.enable = true;
    prettier = {
      enable = true;
      includes = [
        "*.css"
        "*.json"
        "*.jsonc"
      ];
    };
    kdlfmt = {
      enable = true;
      package = pkgs.dev.johnrinehart.kdlfmt;
    };
    ruff-check.enable = true;
    ruff-format.enable = true;
    shellcheck.enable = true;
    shfmt.enable = true;
    statix = {
      enable = true;
      disabled-lints = [ "W20" ];
    };
    taplo.enable = true;
    yamllint = {
      enable = true;
      settings = {
        extends = "default";
        rules.truthy.allowed-values = [
          "true"
          "false"
          "on"
          "off"
        ];
      };
    };
  };
}
