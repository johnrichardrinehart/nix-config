{
  dev.johnrinehart.mycelium = {
    enable = true;
    sopsFile = ../../secrets/nebula-framework.yaml;
    extraLighthouses = [
      {
        address = "10.77.0.10";
        endpoint = "uz801-0.nebula.johnrinehart.dev:4242";
        relay = true;
      }
    ];
    # SSH to KeePass on 2222 and Android Termux peers on 8022.
    firewall.peerSshPorts = [
      "22"
      "2222"
      "8022"
    ];
    firewall.allowPeerHTTPS = true;
  };
}
