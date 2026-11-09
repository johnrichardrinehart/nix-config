{
  sops.secrets.neocache-token = {
    sopsFile = ../../secrets/neocache.yaml;
    key = "token";
    mode = "0400";
  };

  dev.johnrinehart.neocache = {
    # Substitute from fuzzybear3965/fuzzybear3965 (and the module's other
    # default caches), and push every local build there.
    substitute.enable = true;
    push.enable = true;
  };
}
