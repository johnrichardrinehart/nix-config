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
  options.dev.johnrinehart.monstar.libghosttyVtPatches = lib.mkOption {
    type = with lib.types; listOf path;
    default = [ ];
    description = ''
      Patches applied to the libghostty-vt sources that Monstar builds
      against. Drop a patch once Monstar pins a libghostty-vt that
      contains it.
    '';
  };
  config.dev.johnrinehart.monstar.patches = lib.mkBefore [
    ../patches/monstar-font-weight.patch
    ../patches/monstar-synthetic-italic.patch
    ../patches/monstar-kitty-block-shades.patch
    ../patches/monstar-ssh.patch
  ];
  config.dev.johnrinehart.monstar.libghosttyVtPatches = lib.mkBefore [
    ../patches/libghostty-vt-kitty-placeholder-crop.patch
  ];

  config.nixpkgs.overlays = lib.mkAfter [
    (_final: prev: {
      dev = prev.dev // {
        johnrinehart = prev.dev.johnrinehart // {
          monstar = prev.dev.johnrinehart.monstar.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ cfg.patches;
            # Zig builds each package from the project's zig-pkg/<hash>
            # directory and extracts the cached archive there only when
            # the directory is missing. Extract libghostty-vt (the ghostty
            # package) there first and patch it.
            postConfigure =
              (old.postConfigure or "")
              + lib.optionalString (cfg.libghosttyVtPatches != [ ]) ''
                mkdir -p zig-pkg
                tar -xzf "$ZIG_GLOBAL_CACHE_DIR"/p/ghostty-*.tar.gz -C zig-pkg
                ghostty=$(echo zig-pkg/ghostty-*)
              ''
              + lib.concatMapStrings (p: ''
                patch -d "$ghostty" -p1 < ${p}
              '') cfg.libghosttyVtPatches;
          });
        };
      };
    })
  ];
}
