{
  inputs,
  config,
  lib,
  ...
}:
let
  cfg = config.dev.johnrinehart.nix;
  primaryUser = config.dev.johnrinehart.users.primary;
in
{
  options.dev.johnrinehart.nix = {
    enable = lib.mkEnableOption "reasonable Nix settings";

    trusted-users = lib.mkOption {
      default = builtins.attrNames (lib.filterAttrs (_: v: v.isNormalUser) config.users.users) ++ [
        "@wheel"
      ];
    };

    allowedUnfreePackages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Package names permitted by nixpkgs' unfree predicate.";
    };
  };

  config = lib.mkMerge [
    # The primary user drives every build on these machines - rebuilds, remote
    # builders, flake evaluation - so it is trusted whether or not the rest of
    # the Nix settings are enabled, and by name rather than through
    # isNormalUser, which an account pinned below uid 1000 no longer satisfies.
    { nix.settings.trusted-users = [ primaryUser ]; }

    (lib.mkIf (cfg.allowedUnfreePackages != [ ]) {
      nixpkgs.config.allowUnfreePredicate =
        pkg: builtins.elem (lib.getName pkg) cfg.allowedUnfreePackages;
    })

    (lib.mkIf cfg.enable {
      nix = {
        registry = {
          nixpkgs.flake = inputs.nixpkgs;
        };

        nixPath = [ "nixpkgs=${inputs.nixpkgs}" ];

        settings.experimental-features = [
          "nix-command"
          "flakes"
        ];

        settings.download-buffer-size = 256 * 1024 * 1024;

        # Already trusted above; listing it again would repeat it in nix.conf.
        settings.trusted-users = lib.remove primaryUser cfg.trusted-users;
      };
    })
  ];
}
