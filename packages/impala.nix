{
  impala,
  fetchFromGitHub,
  rustPlatform,
}:

# nixos-26.05 ships 0.7.4, whose AP mode ignores the start/stop keys
# (fixed upstream in 0.8.0 by pythops/impala#146).
impala.overrideAttrs (
  finalAttrs: _old: {
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
  }
)
