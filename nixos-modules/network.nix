{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.network;
in
{
  options = {
    dev.johnrinehart.network = {
      enable = lib.mkEnableOption "John's opinionated network config";
      manager = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.enum [
            "networkmanager"
            "iwd"
          ]
        );
        default = null;
        description = "Wireless network manager to configure.";
      };
      migrateLegacyConfigs = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Import known legacy Wi-Fi profiles into the selected manager during activation.";
      };
      preservePredictableInterfaceNames = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Keep path-based wireless interface names when iwd is selected.";
      };
      tools.enable = lib.mkEnableOption "wireless diagnostic and manager frontend tools";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      dev.johnrinehart.network.manager = lib.mkDefault "networkmanager";
      services.tailscale.enable = true;

      networking.nameservers = [
        "1.1.1.1"
        "8.8.8.8"
        "6.6.6.6"
      ];
      # systemd-resolved replaces resolvconf when a host enables it.
      networking.resolvconf.enable = lib.mkDefault true;
      networking.wireless.enable = lib.mkDefault false;
    })

    (lib.mkIf (cfg.enable || cfg.manager != null) {
      dev.johnrinehart.network.tools.enable = lib.mkDefault true;

      environment.systemPackages = lib.mkIf cfg.tools.enable [
        pkgs.iw
      ];
    })

    (lib.mkIf (cfg.manager == "networkmanager") {
      networking.networkmanager.enable = true;
      networking.networkmanager.unmanaged = [ "tailscale0" ];

      environment.systemPackages = [
        pkgs.dev.johnrinehart.legacy-network-configs.toNetworkManager
      ]
      ++ lib.optionals cfg.tools.enable [
        pkgs.wifitui
      ];

      system.activationScripts.importLegacyNetworkConfigsToNetworkManager = lib.mkIf cfg.migrateLegacyConfigs ''
        ${pkgs.dev.johnrinehart.legacy-network-configs.toNetworkManager}/bin/legacy-network-configs-to-nm
      '';
    })

    (lib.mkIf (cfg.manager == "iwd") {
      # iwd runs DHCP on wireless interfaces. dhcpcd must not compete for them.
      networking.dhcpcd.denyInterfaces = [ "wl*" ];
      networking.networkmanager.enable = lib.mkForce false;
      networking.wireless.iwd = {
        enable = true;
        # DefaultInterface makes iwd wait for the driver's interface. The patch
        # stops iwd's own P2P device from ending that wait at boot.
        package = pkgs.iwd.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [ ../patches/iwd-create-p2p-after-default-interface.patch ];
        });
        settings = {
          General.EnableNetworkConfiguration = true;
          Network.NameResolvingService = if config.services.resolved.enable then "systemd" else "resolvconf";
          Settings.AutoConnect = true;
          DriverQuirks.DefaultInterface = "?*";
        };
      };

      systemd.network.links."80-iwd".linkConfig.NamePolicy =
        lib.mkIf cfg.preservePredictableInterfaceNames (lib.mkForce "path");

      environment.systemPackages = [
        pkgs.dev.johnrinehart.legacy-network-configs.toIwd
      ]
      ++ lib.optionals cfg.tools.enable [
        pkgs.dev.johnrinehart.impala
      ];

      system.activationScripts.importLegacyNetworkConfigsToIwd = lib.mkIf cfg.migrateLegacyConfigs ''
        ${pkgs.dev.johnrinehart.legacy-network-configs.toIwd}/bin/legacy-network-config-to-iwd
      '';

      # Phone USB tethers rank behind iwd's Wi-Fi route (300 + ifindex), so a
      # tethered phone is a fallback, not the uplink. The rename lets dhcpcd
      # match them by name; the "en" prefix keeps them inside hosts'
      # `allowInterfaces = [ "en*" ... ]`. Vendor IDs (Google, Samsung,
      # Motorola, OnePlus, Xiaomi) keep cdc_ncm/cdc_ether Ethernet adapters and
      # docks out. ENV, not ATTRS: the driver and the vendor ID sit on
      # different parent devices, and one rule's ATTRS must match one parent.
      services.udev.extraRules = ''
        SUBSYSTEM=="net", ACTION=="add", ENV{ID_USB_DRIVER}=="ipheth|rndis_host", NAME="entether$attr{ifindex}"
        SUBSYSTEM=="net", ACTION=="add", ENV{ID_USB_DRIVER}=="cdc_ncm|cdc_ether", ENV{ID_VENDOR_ID}=="18d1|04e8|22b8|2a70|2717", NAME="entether$attr{ifindex}"
      '';
      # Must stay last in dhcpcd.conf: dhcpcd applies every line after an
      # `interface` line to that interface only.
      networking.dhcpcd.extraConfig = lib.mkAfter ''
        interface entether*
        metric 1000
      '';
    })
  ];
}
