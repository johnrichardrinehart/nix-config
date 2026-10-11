{ fuzzel, fetchurl }:

fuzzel.overrideAttrs (_old: rec {
  version = "1.15.0";
  src = fetchurl {
    url = "https://codeberg.org/dnkl/fuzzel/archive/${version}.tar.gz";
    hash = "sha256-lbbAIvwfHHq1htR8FZRBfMMRv0Hqj1+LVkFHjae1zzs=";
  };
})
