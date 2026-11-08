{
  sops.secrets.neocache-token = {
    sopsFile = ../../secrets/neocache.yaml;
    key = "token";
    mode = "0400";
  };

  # Substitute from fuzzybear3965/fuzzybear3965 (and the module's other default
  # caches); thinkie doesn't push.
  dev.johnrinehart.neocache.substitute.enable = true;
}
