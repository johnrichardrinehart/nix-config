{
  impala,
  fetchFromGitHub,
  rustPlatform,
}:

# nixos-26.05 ships 0.7.4, whose AP mode ignores the start/stop keys
# (fixed upstream in 0.8.0 by pythops/impala#146).
#
# The patch starts the iwd AP profile named by the SSID (iwd.ap(5),
# /var/lib/iwd/ap/<SSID>.ap) when the passphrase is left empty, so the
# profile's passphrase and [IPv4] settings apply. Local only: upstream
# accepts no LLM-written contributions.
impala.overrideAttrs (
  finalAttrs: old: {
    version = "0.9.0";

    src = fetchFromGitHub {
      owner = "pythops";
      repo = "impala";
      rev = "v${finalAttrs.version}";
      hash = "sha256-uCazIX3HToznF2jjTu9+uUeLp2CoQ8cKiP+SxwWlH64=";
    };

    cargoDeps = rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) pname version src;
      hash = "sha256-w8pxZchekifoTzxgiNzUKvx2hsu45EZPr54do2iFmUo=";
    };

    patches = (old.patches or [ ]) ++ [ ../patches/impala-ap-start-profile.patch ];
  }
)
