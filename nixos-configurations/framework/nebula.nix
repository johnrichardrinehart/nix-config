{
  dev.johnrinehart.mycelium = {
    enable = true;
    sopsFile = ../../secrets/nebula-framework.yaml;
    # SSH to KeePass on 2222 and Android Termux peers on 8022.
    firewall.peerSshPorts = [
      "22"
      "2222"
      "8022"
    ];
    firewall.allowPeerHTTPS = true;
  };
}
