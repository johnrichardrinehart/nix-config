# Pinned to unreleased cliphist master for per-entry timestamps, so clipboard
# history shows when each entry was stored: `cliphist list -fields id,timestamp,preview`.
# Landed upstream in sentriz/cliphist@673311f ("feat: add entry metadata and
# configurable list fields"), plus `wipe -older-than` (31d536e, closes
# https://github.com/sentriz/cliphist/issues/100). No release since 0.7.0 ships it.
# Drop this override once nixpkgs carries a cliphist release > 0.7.0.
{ cliphist, fetchFromGitHub }:

cliphist.overrideAttrs (_old: {
  version = "0.7.0-unstable-2026-10-07";
  src = fetchFromGitHub {
    owner = "sentriz";
    repo = "cliphist";
    rev = "f968c4f01395860e8c989c550c1621124927890f";
    hash = "sha256-TK57QB2x9bMXzH08AX/m9oesI+led3gdtho/2YRxfWQ=";
  };
  vendorHash = "sha256-fDl+ul1t2Ux1w5WcCo6YMJtrcC20o+eUEO3NNycSNvI=";
})
