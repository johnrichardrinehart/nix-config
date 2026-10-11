{
  config,
  lib,
  ...
}:
let
  cfg = config.dev.johnrinehart.monstar;
in
{
  options.dev.johnrinehart.monstar.patches = lib.mkOption {
    type = with lib.types; listOf path;
    default = [ ];
    description = "Additional patches applied to the Monstar package.";
  };
  config.dev.johnrinehart.monstar.patches = lib.mkBefore [
    ../patches/monstar-font-weight.patch
    ../patches/monstar-synthetic-italic.patch
    ../patches/monstar-kitty-block-shades.patch
    ../patches/monstar-ssh.patch
  ];

  config.nixpkgs.overlays = lib.mkAfter [
    (_final: prev: {
      dev = prev.dev // {
        johnrinehart = prev.dev.johnrinehart // {
          monstar = prev.dev.johnrinehart.monstar.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ cfg.patches;
          });
        };
      };
    })
  ];
}
