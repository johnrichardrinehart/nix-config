# A "maintenance" boot entry for work on the NVMe drive with / unmounted:
# repartitioning, resizing the ext4 root and its LUKS container, fsck.
#
# The boot menu editor is off (endpoint-security.nix), so stage 1 cannot be
# stopped by typing at the menu; this entry is signed like the others
# instead. It boots stage 1 into rescue.target: systemd asks for the LUKS
# passphrase and opens /dev/mapper/cryptroot, but mounts nothing, and gives
# a root shell (root's password; endpointSecurity.rootHashedPassword).
# With root locked the shell cannot be opened, so the entry exists only once
# that hash is set.
#
# The shell has Wi-Fi (iwd, MT7925 driver and firmware, impala), wired
# Ethernet over USB (DHCP through systemd-networkd), DNS (systemd-resolved),
# CA certificates and omp, so help is at hand while the disk is open:
#
#   impala                        # join a network; iwd remembers it until reboot
#   mount -o ro /dev/mapper/cryptroot /sysroot
#   HOME=/sysroot/home/john omp   # john's omp login; or `omp` and log in anew
#
# Unmount /sysroot again before resizing anything.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  rootHashedPassword = config.dev.johnrinehart.endpointSecurity.rootHashedPassword;
  iwd = config.networking.wireless.iwd.package;
  # Not bin/omp: that is a bash script whose wrapped library path drags in
  # PipeWire and FFmpeg (1 GiB) for voice. The binary and its native module
  # (lib/omp, 300 MB) are enough for a text session. The binary has no
  # RUNPATH and finds libpthread and libm next to its loader, so all of that
  # glibc's lib/ goes along.
  ompPackage = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.omp;
  omp = "${ompPackage}/lib/omp";

  iwdConf = (pkgs.formats.ini { }).generate "main.conf" {
    General.EnableNetworkConfiguration = true;
    Network.NameResolvingService = "systemd";
    Settings.AutoConnect = true;
    DriverQuirks.DefaultInterface = "?*";
  };
in
{
  specialisation = lib.mkIf (rootHashedPassword != null) {
    maintenance.configuration = {
      system.nixos.tags = [ "maintenance" ];
      boot.kernelParams = [ "rd.systemd.unit=rescue.target" ];

      boot.initrd = {
        availableKernelModules = [
          # Wi-Fi; its firmware comes along (modinfo).
          "mt7925e"
          # USB Ethernet: Framework's card (RTL8156), common dongles and docks,
          # phone tethering.
          "r8152"
          "ax88179_178a"
          "cdc_ether"
          "cdc_ncm"
          "rndis_host"
          "ipheth"
        ];
        # iwd.service may not load modules (ProtectKernelModules), so the
        # AF_ALG interfaces and ciphers its WPA handshakes ask for are loaded
        # up front.
        kernelModules = [
          "algif_hash"
          "algif_skcipher"
          "algif_aead"
          "pkcs8_key_parser"
          "aes"
          "cbc"
          "ctr"
          "ccm"
          "gcm"
          "cmac"
          "des"
          "md4"
          "md5"
          "sha512"
        ];
        extraFirmwarePaths = [
          "regulatory.db"
          "regulatory.db.p7s"
        ];

        systemd = {
          initrdBin = [
            pkgs.cryptsetup
            pkgs.gptfdisk
            pkgs.parted
            pkgs.util-linux
            pkgs.iproute2
            pkgs.iputils
            pkgs.procps
            pkgs.findutils
            pkgs.gnugrep
            pkgs.gnused
            pkgs.curl
            iwd
            pkgs.dev.johnrinehart.impala
          ];
          extraBin.omp = "${omp}/omp";

          contents = {
            "/etc/iwd/main.conf".source = iwdConf;
            "/etc/ssl/certs/ca-certificates.crt".source = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
            # The stage 1 bus allows only dbus's and systemd's services; iwd
            # owns net.connman.iwd, which its policy file permits.
            "/etc/dbus-1".source = lib.mkForce (
              pkgs.makeDBusConf.override {
                inherit (config.services.dbus) apparmor;
                dbus = config.services.dbus.dbusPackage;
                suidHelper = "/bin/false";
                serviceDirectories = [
                  config.services.dbus.dbusPackage
                  config.boot.initrd.systemd.package
                  iwd
                ];
              }
            );
          };

          packages = [ iwd ];
          storePaths = [
            "${iwd}/libexec/iwd"
            "${iwd}/share/dbus-1"
            omp
            "${ompPackage.stdenv.cc.libc}/lib"
          ];
          services.iwd.wantedBy = [ "rescue.target" ];

          # Wired links; iwd configures Wi-Fi itself.
          network = {
            enable = true;
            wait-online.enable = false;
            networks."10-wired" = {
              matchConfig.Name = "en* eth*";
              networkConfig.DHCP = "yes";
            };
          };
          services.systemd-networkd.wantedBy = [ "rescue.target" ];
        };
      };
    };
  };
}
