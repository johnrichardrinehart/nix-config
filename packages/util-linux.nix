{
  lib,
  fetchurl,
  util-linux,
}:

util-linux.overrideAttrs (
  finalAttrs: old: {
    version = "2.42.4";

    src = fetchurl {
      url = "mirror://kernel/linux/utils/util-linux/v${lib.versions.majorMinor finalAttrs.version}/util-linux-${finalAttrs.version}.tar.xz";
      hash = "sha256-+9YqEAq3u4dGugZhJVw8SBhbHpAhUHxiTaAfvGljMOw=";
    };

    # 2.42.4 contains the libmount build fix and the CVE-2026-78408 fix that
    # nixpkgs patches into 2.42.3.
    patches =
      lib.filter (
        patch:
        !lib.elem (baseNameOf patch) [
          "libmount-build-fix.patch"
          "CVE-2026-78408.patch"
        ]
      ) old.patches
      ++ [ ../patches/util-linux.patch ];
  }
)
