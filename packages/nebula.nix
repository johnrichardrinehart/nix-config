{
  buildGo127Module,
  fetchFromGitHub,
  nebula,
}:

(nebula.override { buildGoModule = buildGo127Module; }).overrideAttrs (
  finalAttrs: old: {
    # 1.11.0 stops leaking debug-console sessions that end with an `exec`
    # request (slackhq/nebula#1640). On 1.10.3 each `ssh … <command>` leaked
    # ~37 KiB, and the registry's console polling OOMed the lighthouse.
    version = "1.12.0";

    src = fetchFromGitHub {
      owner = "slackhq";
      repo = "nebula";
      tag = "v${finalAttrs.version}";
      hash = "sha256-N50vOtzp1ZikqCkVoS2MRMCY2otg8QHAvVJwfgCbyRI=";
    };

    vendorHash = "sha256-tmNpGNjMY5PtJO/DU+eoZy2Miqu2VzBTiHKThVCDVZs=";

    # A relayed tunnel that sat idle while its relay tunnel was replaced (sleep,
    # network change) loses its relay, and nebula drops its traffic until dead
    # tunnel detection, ~15-20 s. Re-handshake on the first send instead (~0.4 s).
    patches = (old.patches or [ ]) ++ [
      ../patches/nebula-rehandshake-orphaned-relay.patch
      # On macOS a sendto can fail with EAGAIN or ENOBUFS for a while, for example
      # while the EndpointSecurity send check is throttled (slackhq/nebula#1901).
      # 1.12 drops the datagram at once, so no handshake reply got out. Wait up
      # to 10 ms for the socket before dropping.
      ../patches/nebula-darwin-retry-stalled-send.patch
    ];
  }
)
