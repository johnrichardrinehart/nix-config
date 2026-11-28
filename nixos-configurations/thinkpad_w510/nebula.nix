{
  # `thinkie` is 10.77.0.8/24 in the peer group. The module defaults admit
  # ICMP and SSH from peers, and permit ICMP and SSH to peers.
  dev.johnrinehart.mycelium = {
    enable = true;
    sopsFile = ../../secrets/nebula-thinkie.yaml;
    # SSH to KeePass on 2222 and Android Termux peers on 8022.
    firewall.peerSshPorts = [
      "22"
      "2222"
      "8022"
    ];
    # HTTPS to peers, e.g. https://keepass.mycelium.internal.
    firewall.allowPeerHTTPS = true;
  };
}
