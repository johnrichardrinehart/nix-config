{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.network;
  uplinkWatchdog = pkgs.writeShellApplication {
    name = "uplink-watchdog";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.iproute2
      pkgs.iputils
      pkgs.jq
      pkgs.systemd
    ];
    # A route that vanishes mid-round must not kill the loop.
    bashOptions = [
      "nounset"
      "pipefail"
    ];
    text = builtins.readFile ./uplink-watchdog.sh;
  };
  # Sets keys in existing iwd profiles (iwd.network(5)) without touching
  # the rest, such as their passphrases. Arguments come in fours: profile
  # file name, group, key, value.
  iwdProfileSettings = pkgs.writeShellApplication {
    name = "iwd-profile-settings";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.diffutils
    ];
    text = ''
      while (($# >= 4)); do
        file=/var/lib/iwd/$1 group=$2 key=$3 value=$4
        shift 4
        [[ -f $file ]] || continue
        tmp=$(mktemp "$file.XXXXXX")
        awk -v group="$group" -v key="$key" -v value="$value" '
          function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
          function put() { if (!done) { print key "=" value; done = 1 } }
          /^[[:space:]]*\[/ {
            if (ingroup) put()
            ingroup = (trim($0) == "[" group "]")
            seen = seen || ingroup
            print; next
          }
          ingroup && index($0, "=") && trim(substr($0, 1, index($0, "=") - 1)) == key { put(); next }
          { print }
          END {
            if (ingroup) put()
            else if (!seen) { print ""; print "[" group "]"; print key "=" value }
          }
        ' "$file" >"$tmp"
        if cmp -s "$file" "$tmp"; then
          rm -f "$tmp"
        else
          chmod 600 "$tmp"
          mv "$tmp" "$file"
        fi
      done
    '';
  };
  iwdProfileSettingsArgs = lib.concatLists (
    lib.mapAttrsToList (
      file: groups:
      lib.concatLists (
        lib.mapAttrsToList (
          group: keys:
          lib.mapAttrsToList (key: value: [
            file
            group
            key
            (if lib.isBool value then lib.boolToString value else toString value)
          ]) keys
        ) groups
      )
    ) cfg.iwd.profileSettings
  );
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
      iwd.profileSettings = lib.mkOption {
        type =
          with lib.types;
          attrsOf (
            attrsOf (
              attrsOf (oneOf [
                bool
                int
                str
              ])
            )
          );
        default = { };
        example = {
          "MyNetwork.psk"."BSS.12:34:56:78:9a:bc".UseDefaultEccGroup = true;
        };
        description = ''
          Keys to set in iwd network profiles (iwd.network(5)), by profile
          file name in /var/lib/iwd, group and key. Profiles hold their
          passphrases, so they stay iwd's state: activation sets the listed
          keys in profiles that exist then and leaves everything else alone.
          Removing an entry does not remove the key from the profile.

          For example, [BSS.<address>].UseDefaultEccGroup=true (from
          patches/iwd-per-bss-default-ecc-group.patch) makes the WPA3 (SAE)
          handshake with one access point always use ECC group 19. Without
          it iwd learns a group per network and keeps it for its lifetime,
          so an access point that rejects that group (status 77) can stay
          unreachable until iwd restarts.
        '';
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
        # DefaultInterface makes iwd wait for the driver's interface.
        #
        # patches/iwd/ is the access point series: iwd 3.12's AP sends to
        # clients at legacy 802.11g rates and its DHCP server advertises no
        # router unless one is configured. The series fixes both, adds VHT
        # (80 MHz on 5 GHz) and a [General].Hidden profile setting (iwd.ap(5)),
        # and skips the EAP-SIM/AKA unit tests on kernels whose AF_ALG has no
        # HMAC, as the other HMAC tests do. It is on its way upstream.
        #
        # Of the next two patches, the first stops iwd's own P2P device from
        # ending the DefaultInterface wait at boot. The second makes scans for
        # hidden networks dwell 15 TU per channel where the driver allows it
        # (packages/iwlwifi does), so slow-answering hidden APs are found.
        #
        # The last adds [BSS.<address>].UseDefaultEccGroup to profiles, so
        # one access point of a network can be held to ECC group 19 while
        # the others keep the most secure group.
        package = pkgs.iwd.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [
            ../patches/iwd/0001-ap-Default-the-DHCP-router-to-the-AP-address.patch
            ../patches/iwd/0002-auto-t-Check-the-AP-advertises-itself-as-router.patch
            ../patches/iwd/0003-ap-Pass-station-HT-capabilities-and-WMM-to-the-kerne.patch
            ../patches/iwd/0004-band-Add-band_freq_to_vht_chandef.patch
            ../patches/iwd/0005-wiphy-Add-wiphy_get_vht_capabilities.patch
            ../patches/iwd/0006-ap-Support-VHT-and-80MHz-channels-on-5GHz.patch
            ../patches/iwd/0007-unit-Skip-EAP-SIM-AKA-tests-without-HMAC-support.patch
            ../patches/iwd/0008-ap-Add-a-General-.Hidden-profile-setting.patch
            ../patches/iwd-create-p2p-after-default-interface.patch
            ../patches/iwd-dwell-longer-on-scans-for-hidden-networks.patch
            ../patches/iwd-per-bss-default-ecc-group.patch
          ];
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

      system.activationScripts.iwdProfileSettings = lib.mkIf (cfg.iwd.profileSettings != { }) ''
        ${lib.getExe iwdProfileSettings} ${lib.escapeShellArgs iwdProfileSettingsArgs}
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

      # dhcpcd and iwd rank default routes by link type alone. Demote any
      # whose uplink cannot reach the internet; see uplink-watchdog.sh.
      systemd.services.uplink-watchdog = {
        description = "Demote default routes whose uplink cannot reach the internet";
        wantedBy = [ "multi-user.target" ];
        environment.UPLINK_RESOLVED = if config.services.resolved.enable then "1" else "0";
        serviceConfig = {
          ExecStart = lib.getExe uplinkWatchdog;
          Restart = "always";
          RestartSec = 5;
          CapabilityBoundingSet = [
            "CAP_NET_ADMIN"
            "CAP_NET_RAW"
          ];
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
        };
      };
    })
  ];
}
