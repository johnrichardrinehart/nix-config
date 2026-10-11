{
  fetchFromGitHub,
  nebula,
}:

nebula.overrideAttrs (
  finalAttrs: _old: {
    # 1.11.0 stops leaking debug-console sessions that end with an `exec`
    # request (slackhq/nebula#1640). On 1.10.3 each `ssh … <command>` leaked
    # ~37 KiB, and the registry's console polling OOMed the lighthouse.
    version = "1.11.2";

    src = fetchFromGitHub {
      owner = "slackhq";
      repo = "nebula";
      tag = "v${finalAttrs.version}";
      hash = "sha256-jzXfKPefw+V2RQBUuxXWoKj1CsVrB4GHdzZJD0zZ0g8=";
    };

    vendorHash = "sha256-5+DTf3muD82UKZ+toBh1Ypz/5pvIVZIaqA5j3DBhppU=";
  }
)
