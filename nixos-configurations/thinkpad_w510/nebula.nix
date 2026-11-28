{
  # `thinkie` is 10.77.0.8/24 in the peer group. The module defaults admit
  # ICMP and SSH from peers, and permit ICMP and SSH to peers.
  dev.johnrinehart.mycelium = {
    enable = true;
    sopsFile = ../../secrets/nebula-thinkie.yaml;
    # HTTPS to peers, e.g. https://keepass.mycelium.internal.
    firewall.allowPeerHTTPS = true;
  };
}
