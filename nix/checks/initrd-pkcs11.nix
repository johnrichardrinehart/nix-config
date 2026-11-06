# Boots from a LUKS2 root that stage 1 unlocks with a smart card. QEMU
# emulates a USB CCID reader with a card (libcacard) that holds the RSA keys
# of an NSS database.
{ lib, pkgs }:
let
  pin = "77777777";
  # libcacard needs three certificates with private keys. It checks the card
  # PIN against the password of the NSS database.
  cardKeys = pkgs.runCommand "initrd-pkcs11-card-keys" { nativeBuildInputs = [ pkgs.nss.tools ]; } ''
    mkdir "$out"
    echo -n ${pin} > pin
    certutil -N -d "sql:$out" -f pin
    head -c 64 /dev/urandom > noise
    for i in 1 2 3; do
      certutil -S -d "sql:$out" -f pin -n "cert$i" -s "CN=cert$i" -x -t CT,C,C \
        -k rsa -g 2048 -z noise --keyUsage digitalSignature,keyEncipherment
    done
  '';
  openscConf = pkgs.writeText "opensc.conf" ''
    app default {
      reader_driver pcsc {
        enable_pinpad = false;
      }
    }
  '';
in
pkgs.testers.runNixOSTest {
  name = "initrd-pkcs11";
  # The driver's boot wait has no timeout of its own.
  globalTimeout = 900;

  # The test runner's QEMU has no smart card support.
  qemu.package = pkgs.qemu;

  nodes.machine = {
    imports = [ ../../nixos-modules/initrd-pkcs11.nix ];

    dev.johnrinehart.initrdPkcs11.enable = true;

    virtualisation = {
      emptyDiskImages = [ 512 ];
      useBootLoader = true;
      useEFIBoot = true;
      # Stage 2 of the encrypted root uses the host's Nix store.
      mountHostNixStore = true;
      qemu.options = [
        "-device piix3-usb-uhci,id=uhci"
        "-device usb-ccid,bus=uhci.0"
        # libcacard opens the NSS database read-write; the test copies it.
        "-device ccid-card-emulated,backend=certificates,db=sql:/tmp/card-keys,cert1=cert1,cert2=cert2,cert3=cert3"
      ];
    };

    boot.loader.systemd-boot.enable = true;
    boot.initrd.systemd.enable = true;
    environment.systemPackages = [ pkgs.cryptsetup ];

    # QEMU's reader claims a PIN pad but cannot verify a PIN with it. On a
    # PIN-pad reader, systemd leaves PIN entry to the reader, so OpenSC must
    # ignore the PIN pad and take the PIN from systemd.
    environment.etc."opensc.conf".source = openscConf;
    boot.initrd.systemd.contents."/etc/opensc.conf".source = lib.mkForce openscConf;

    specialisation.boot-luks.configuration = {
      boot.initrd.luks.devices = lib.mkVMOverride {
        cryptroot = {
          device = "/dev/vdb";
          crypttabExtraOpts = [ "pkcs11-uri=auto" ];
        };
      };
      virtualisation.rootDevice = "/dev/mapper/cryptroot";
      # The PKCS#11 login reads the PIN from $PIN before it asks on the
      # console, so stage 1 unlocks without a keyboard.
      boot.initrd.systemd.services."systemd-cryptsetup@cryptroot" = {
        overrideStrategy = "asDropin";
        environment.PIN = pin;
      };
    };
  };

  testScript =
    { nodes, ... }:
    let
      bootLuks = nodes.machine.specialisation.boot-luks.configuration.system.build.toplevel;
    in
    ''
      import shutil, subprocess
      shutil.copytree("${cardKeys}", "/tmp/card-keys")
      subprocess.run(["chmod", "-R", "u+w", "/tmp/card-keys"], check=True)
      machine.wait_for_unit("multi-user.target")
      print(machine.succeed("systemd-cryptenroll --pkcs11-token-uri=list 2>&1"))
      machine.succeed("echo -n supersecret | cryptsetup luksFormat -q --type luks2 --iter-time=1 /dev/vdb -")
      machine.succeed("echo -n supersecret | cryptsetup luksOpen -q /dev/vdb cryptroot")
      machine.succeed("mkfs.ext4 -q /dev/mapper/cryptroot")
      machine.succeed("cryptsetup luksClose cryptroot")
      # The card holds three keys, so "auto" refuses to choose. Name the key
      # of one certificate by its PKCS#11 URI.
      certs = machine.succeed(
          "pkcs11-tool --module ${pkgs.opensc}/lib/opensc-pkcs11.so --login --pin ${pin} --list-objects --type cert"
      )
      print(certs)
      uri = next(line.split()[1] for line in certs.splitlines() if line.strip().startswith("uri:"))
      machine.succeed(f"PASSWORD=supersecret PIN=${pin} systemd-cryptenroll --pkcs11-token-uri='{uri}' /dev/vdb 2>&1 | systemd-cat")
      machine.succeed("cryptsetup luksDump /dev/vdb | grep -F systemd-pkcs11")

      machine.succeed("${bootLuks}/bin/switch-to-configuration boot")
      machine.succeed("sync")
      # switch-to-configuration adds the specialisation's entry but keeps the
      # default entry.
      machine.succeed("bootctl set-default \"$(ls /boot/loader/entries | grep boot-luks)\"")
      machine.crash()

      machine.start()
      machine.wait_for_unit("multi-user.target", timeout=300)
      assert "/dev/mapper/cryptroot on / type ext4" in machine.succeed("mount")
      machine.succeed("journalctl -b -u systemd-cryptsetup@cryptroot.service | grep -F 'security token'")
    '';
}
