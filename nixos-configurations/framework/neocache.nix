{
  sops.secrets.neocache-token = {
    sopsFile = ../../secrets/neocache.yaml;
    key = "token";
    mode = "0400";
  };

  dev.johnrinehart.neocache = {
    substitute.enable = true;
    push.enable = true;
  };
}
