_: {
  # iwd configures Wi-Fi. dhcpcd configures wired interfaces.
  networking.hostName = "framie";
  networking.useDHCP = true;
  networking.interfaces.wlp170s0.useDHCP = false;
  networking.dhcpcd.allowInterfaces = [
    "en*"
    "eth*"
  ];
  # Do not hold boot for a lease when no cable is plugged in.
  networking.dhcpcd.wait = "background";
  # dhcpcd defaults to metric 1000 + ifindex, which loses to the iwd route
  # (metric 302). Prefer a wired link when one is plugged in.
  networking.dhcpcd.extraConfig = "metric 200";
  dev.johnrinehart.network = {
    enable = true;
    manager = "iwd";
  };
  # With DriverQuirks.DefaultInterface, iwd must find the kernel-created
  # interface when it sets up the wiphy. If iwd starts while iwlmvm is still
  # registering the card, iwd can miss the interface and expose no device.
  # The device unit appears only after udev renames the interface.
  systemd.services.iwd = {
    wants = [ "sys-subsystem-net-devices-wlp170s0.device" ];
    after = [ "sys-subsystem-net-devices-wlp170s0.device" ];
  };
}
