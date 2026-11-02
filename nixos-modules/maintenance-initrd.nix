# A "maintenance" boot entry for work on the system drive with / unmounted:
# repartitioning, resizing the root file system and its LUKS container, fsck.
#
# The entry is a specialisation, so the boot loader lists it beside each
# generation and lanzaboote signs it like the others. It boots stage 1 into
# rescue.target: systemd asks for the LUKS passphrases and opens the
# containers, but mounts nothing, and gives a root shell.
#
# The shell has Wi-Fi (iwd, the drivers in wifiKernelModules with their
# firmware, impala), wired Ethernet over USB (DHCP through
# systemd-networkd), DNS (systemd-resolved), CA certificates and nix, so
# more tools are at hand while the disk is open. The shell is root already;
# run0 and sudo are there for commands typed out of habit. nix runs without
# a daemon and keeps its store in RAM:
#
#   impala                        # join a network; iwd remembers it until reboot
#   mount -o ro /dev/mapper/cryptroot /sysroot   # or the plain root partition
#   nix shell nixpkgs#btrfs-progs # anything else, from the binary caches
#
# Unmount /sysroot again before resizing anything.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.maintenanceInitrd;
  iwd = config.networking.wireless.iwd.package;
  iwdConf = (pkgs.formats.ini { }).generate "main.conf" {
    General.EnableNetworkConfiguration = true;
    Network.NameResolvingService = "systemd";
    Settings.AutoConnect = true;
    DriverQuirks.DefaultInterface = "?*";
  };

  # Single-user, as root: no daemon, build users or sandbox in stage 1.
  # Substituters as the installed system's.
  nixConf = pkgs.writeText "nix.conf" ''
    experimental-features = nix-command flakes
    build-users-group =
    sandbox = false
    substituters = ${
      toString (config.nix.settings.substituters ++ config.nix.settings.extra-substituters or [ ])
    }
    trusted-public-keys = ${
      toString (
        config.nix.settings.trusted-public-keys ++ config.nix.settings.extra-trusted-public-keys or [ ]
      )
    }
  '';

  # sudo and run0 (as systemd-run0) open PAM sessions. Stage 1 has only
  # root, which neither asks to authenticate; one stack, as PAM's "other",
  # lets root through and refuses anyone else.
  pamOther = pkgs.writeText "other" ''
    auth     sufficient ${pkgs.pam}/lib/security/pam_rootok.so
    auth     required   ${pkgs.pam}/lib/security/pam_deny.so
    account  required   ${pkgs.pam}/lib/security/pam_permit.so
    password required   ${pkgs.pam}/lib/security/pam_deny.so
    session  required   ${pkgs.pam}/lib/security/pam_permit.so
  '';
in
{
  options.dev.johnrinehart.maintenanceInitrd = {
    enable = lib.mkEnableOption ''
      a "maintenance" boot entry that stops stage 1 at a root shell with the
      LUKS containers open and nothing mounted
    '';

    emergencyAccess = lib.mkOption {
      type = lib.types.either (lib.types.enum [ true ]) (lib.types.strMatching "[$].+");
      example = "$y$j9T$...";
      description = ''
        Access to the root shell of the maintenance entry, as
        boot.initrd.systemd.emergencyAccess: a crypt(3) hash of root's
        password, or `true` for a shell without a password. It applies to
        the maintenance entry only. The hash goes into the world-readable
        Nix store.
      '';
    };

    wifiKernelModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "mt7925e" ];
      description = ''
        Kernel modules of the Wi-Fi card. The initrd also gets the firmware
        files that the modules name (modinfo).
      '';
    };
  };

  config.specialisation = lib.mkIf cfg.enable {
    maintenance.configuration = {
      system.nixos.tags = [ "maintenance" ];
      boot.kernelParams = [ "rd.systemd.unit=rescue.target" ];
      # Kernel messages at a host's debug log level print over the shell and
      # over full-screen programs such as impala. `dmesg` still shows them.
      # No host that enables this entry raises the level, so this is
      # redundant today. It only guards against a host that does.
      boot.consoleLogLevel = lib.mkForce 4;

      boot.initrd = {
        availableKernelModules =
          cfg.wifiKernelModules
          # cryptsetup, also on hosts without LUKS devices, which do not get
          # dm-crypt or the ciphers in their initrd otherwise.
          ++ [
            "dm_mod"
            "dm_crypt"
          ]
          ++ config.boot.initrd.luks.cryptoModules
          ++ lib.optional pkgs.stdenv.hostPlatform.isx86_64 "aesni_intel"
          ++ [
            # USB Ethernet: Framework's card (RTL8156), common dongles and docks,
            # phone tethering.
            "r8152"
            "ax88179_178a"
            "cdc_ether"
            "cdc_ncm"
            "rndis_host"
            "ipheth"
            # File systems to repair or mount besides ext4 and the ESP's vfat:
            # USB drives, other machines' disks.
            "btrfs"
            "xfs"
            "exfat"
            "ntfs3"
            "loop"
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
          inherit (cfg) emergencyAccess;

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
            # reset, clear and tput, for a terminal that a program left in
            # raw mode.
            pkgs.ncurses
            pkgs.curl
            iwd
            pkgs.dev.johnrinehart.impala
            pkgs.sudo
            config.nix.package
            # File system repair and data recovery. e2fsprogs (e2fsck,
            # resize2fs, tune2fs, debugfs) is in every initrd already.
            pkgs.dosfstools
            # Grows or shrinks a FAT file system, such as the ESP.
            pkgs.fatresize
            pkgs.exfatprogs
            pkgs.btrfs-progs
            pkgs.xfsprogs
            pkgs.ntfs3g
            pkgs.testdisk
            pkgs.ddrescue
          ];
          contents = {
            "/etc/iwd/main.conf".source = iwdConf;
            "/etc/ssl/certs/ca-certificates.crt".source = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
            "/etc/nix/nix.conf".source = nixConf;
            "/etc/pam.d/other".source = pamOther;
            "/etc/sudoers".text = ''
              root ALL=(ALL:ALL) SETENV: ALL
            '';
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
            # Only binaries and their libraries are copied otherwise: sudo
            # loads its policy from libexec, PAM its modules from lib/security.
            "${pkgs.sudo}/libexec/sudo"
            "${pkgs.pam}/lib/security"
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
