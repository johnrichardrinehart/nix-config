# Unlock LUKS2 containers in stage 1 with a PKCS#11 smart card, such as a
# PIV card in a CCID reader. Enroll a card in a running system:
#
#   systemd-cryptenroll --pkcs11-token-uri=list
#   systemd-cryptenroll --pkcs11-token-uri=auto /dev/sdXN
#
# Then add "pkcs11-uri=auto" to the container's
# boot.initrd.luks.devices.<name>.crypttabExtraOpts. systemd-cryptsetup asks
# for the card PIN. It waits token-timeout (30 s by default) for a card, then
# asks for a passphrase.
#
# Add the option only to LUKS2 containers. On a LUKS1 container,
# systemd-cryptsetup stops with "Automatic PKCS#11 metadata requires LUKS2
# device." and asks for no passphrase. Check with `cryptsetup luksDump`.
#
# The chain in stage 1: the systemd PKCS#11 token plugin, p11-kit, OpenSC
# (opensc-pkcs11.so), pcscd with the CCID driver, and the reader.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.initrdPkcs11;
  systemd = config.boot.initrd.systemd.package;
  opensc = pkgs.opensc;
  # Stage 1 has no polkit. OpenSC loads the client library of this package.
  pcsclite = pkgs.pcsclite;
  ccidDrivers = "${pkgs.ccid}/pcsc/drivers";
  openscModule = "module: ${opensc}/lib/opensc-pkcs11.so";
  # An empty file stops pcscd from parsing every file in /etc as reader.conf.
  readerConf = pkgs.writeText "reader.conf" "";
  # `--pkcs11-token-uri=auto` tests the token flags where it means the slot
  # flags, so it rejects every token without CKF_RNG, such as PIVKey cards.
  # The fix is in libsystemd-shared, so this installs systemd-cryptenroll from
  # a patched systemd. The system keeps the stock systemd: boot unlock with
  # "pkcs11-uri=auto" takes the URI from the LUKS header, not from this check.
  cryptenroll =
    let
      patched = config.systemd.package.overrideAttrs (old: {
        patches = old.patches or [ ] ++ [ ../patches/systemd-pkcs11-auto-check-slot-flags.patch ];
      });
    in
    pkgs.runCommand "systemd-cryptenroll-pkcs11-auto" { } ''
      mkdir -p $out/bin
      ln -s ${patched}/bin/systemd-cryptenroll $out/bin/systemd-cryptenroll
    '';
in
{
  options.dev.johnrinehart.initrdPkcs11.enable = lib.mkEnableOption ''
    PKCS#11 smart cards (OpenSC, pcscd, CCID readers) for LUKS2 unlock in
    the systemd stage 1
  '';

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.boot.initrd.systemd.enable;
        message = "dev.johnrinehart.initrdPkcs11 needs boot.initrd.systemd.enable.";
      }
    ];

    # systemd-cryptenroll finds the card through the same p11-kit module.
    services.pcscd.enable = true;
    environment.systemPackages = [
      opensc
      (lib.hiPrio cryptenroll)
    ];
    environment.etc."pkcs11/modules/opensc.module".text = openscModule;

    boot.initrd.systemd = {
      storePaths = [
        {
          source = "${systemd}/lib/cryptsetup/libcryptsetup-token-systemd-pkcs11.so";
          # libsystemd-shared opens libp11-kit with dlopen().
          dlopen.features = [ "p11-kit" ];
        }
        "${opensc}/lib/opensc-pkcs11.so"
        # OpenSC opens libpcsclite.so with dlopen(), and libpcsclite.so opens
        # libpcsclite_real.so.
        "${lib.getLib pcsclite}/lib"
        (lib.getExe pcsclite)
        ccidDrivers
        readerConf
      ];

      contents = {
        "/etc/pkcs11/modules/opensc.module".text = openscModule;
        "/etc/opensc.conf".source = "${opensc}/etc/opensc.conf";
      };

      # Socket units order after sysinit.target by default, and sysinit.target
      # orders after cryptsetup.target. These units opt out so that pcscd
      # can run before systemd-cryptsetup asks for the card.
      sockets.pcscd = {
        description = "PC/SC Smart Card Daemon Activation Socket";
        unitConfig.DefaultDependencies = false;
        wantedBy = [ "cryptsetup.target" ];
        wants = [ "cryptsetup-pre.target" ];
        before = [ "cryptsetup-pre.target" ];
        listenStreams = [ "/run/pcscd/pcscd.comm" ];
        socketConfig.SocketMode = "0600";
      };

      services.pcscd = {
        description = "PC/SC Smart Card Daemon";
        unitConfig.DefaultDependencies = false;
        requires = [ "pcscd.socket" ];
        # pcscd finds readers that are present at start through udev.
        after = [
          "pcscd.socket"
          "systemd-udev-trigger.service"
        ];
        environment.PCSCLITE_HP_DROPDIR = ccidDrivers;
        serviceConfig.ExecStart = "${lib.getExe pcsclite} --foreground --auto-exit -c ${readerConf}";
      };
    };
  };
}
