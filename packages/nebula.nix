{
  buildGo127Module,
  fetchFromGitHub,
  nebula,
}:

(nebula.override { buildGoModule = buildGo127Module; }).overrideAttrs (
  finalAttrs: _old: {
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
  }
)
