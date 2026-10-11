{ fetchurl, buildLinux, ... }@args:

buildLinux (
  args
  // rec {
    version = "5.16.10";
    modDirVersion = "5.16.10";

    kernelPatches = [
      {
        name = "libsubcmd-fix-realloc-use-after-free";
        patch = fetchurl {
          url = "https://github.com/torvalds/linux/commit/52a9dab6d892763b2a8334a568bd4e2c1a6fde66.patch";
          hash = "sha256-HzDE5my5zNp5CfppOAXJSoB5TirxHLXsz2Xhw2lm3ak=";
        };
      }
      {
        name = "gcc-15-c-dialect";
        patch = ../patches/linux-5.16-gcc-15.patch;
      }
      {
        name = "pahole-skip-unsupported-btf-enum64";
        patch = fetchurl {
          url = "https://github.com/gregkh/linux/commit/b775fbf532dc01ae53a6fc56168fd30cb4b0c658.patch";
          hash = "sha256-iU4huwK7zGgfEN+YTsaTETuc8rRkn6DCwFXaBvxQwJw=";
        };
      }
    ];

    src = fetchurl {
      url = "https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-${version}.tar.xz";
      sha256 = "sha256-DE1vAIGABZOFLrFVsB4Jt4tbxp16VT/Fj1rSBw+QI54=";
    };

  }
  // (args.argsOverride or { })
)
