# The endpoint security baseline of the installed Framework 13 Pro. Only the
# installed system (default.nix) imports it: the netbooted one runs from RAM,
# keeps no state and cannot boot with Secure Boot on (iPXE is not signed).
#
# The baseline itself is here. What identifies an organisation (its
# monitoring agents, the tailnet's routes, the USB devices to allow, where
# keys are kept) is set downstream, as for the work layer. README "Endpoint
# security" lists the steps that only the firmware or a person can do.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.endpointSecurity;
  primaryUser = config.dev.johnrinehart.users.primary;
  idle = config.home-manager.users.${primaryUser}.idle;
  # on-idle (packages/on-idle.nix) waits this long after hypridle's short
  # timeout before it runs `loginctl lock-session`.
  onIdleLockDelaySeconds = 5;
in
{
  imports = [ inputs.lanzaboote.nixosModules.lanzaboote ];

  options.dev.johnrinehart.endpointSecurity = {
    screenLockSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5 * 60;
      description = ''
        Longest time the desktop may stay idle before it locks. Evaluation
        fails when the idle settings lock later than this.
      '';
    };

    rootHashedPassword = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[$].+");
      default = null;
      example = "$y$j9T$...";
      description = ''
        crypt(3) hash of root's password, which every activation writes
        back to /etc/shadow, so a `passwd` as root lasts only until the next
        boot or switch. The initrd's emergency shell takes the same password.
        `null` locks root in both. The hash goes into the world-readable Nix
        store. The primary user's password stays mutable: set at account
        creation, then changed with `passwd`.
      '';
    };
  };

  config = {
    # users.mutableUsers keeps every existing /etc/shadow entry, root's
    # included, whatever users.users.root declares; the primary user needs
    # that to change their own password. So root's entry is enforced here,
    # after the users activation step.
    system.activationScripts.rootPassword = {
      deps = [ "users" ];
      text = ''
        ${lib.getExe' pkgs.shadow "usermod"} -p ${
          lib.escapeShellArg (if cfg.rootHashedPassword == null then "!" else cfg.rootHashedPassword)
        } root
      '';
    };

    # The initrd has its own root account, locked by default, so a failed
    # file system check of the LUKS root left an emergency shell that no one
    # could open. lanzaboote signs the initrd's hash into the UKI, so the
    # hash cannot be changed without breaking Secure Boot.
    boot.initrd.systemd.emergencyAccess = cfg.rootHashedPassword;

    # Secure Boot with our own keys (lanzaboote). The first boot after
    # `install-to-disk` runs unsigned, creates the keys in /var/lib/sbctl,
    # signs the ESP, puts the key enrollment files on it and reboots;
    # systemd-boot then enrolls the keys if the firmware is in Setup Mode.
    # Microsoft's keys stay enrolled: option ROMs and fwupd's capsules need
    # them.
    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.lanzaboote = {
      enable = true;
      pkiBundle = "/var/lib/sbctl";
      configurationLimit = 20;
      autoGenerateKeys.enable = true;
      # Rebooting is done below, only after the keys were staged.
      autoEnrollKeys.enable = true;
      # No kernel command line edits at the boot menu (init=/bin/sh).
      settings.editor = false;
    };
    environment.systemPackages = [ pkgs.sbctl ];

    # systemd-boot enrolls the staged keys only while the firmware is in
    # Setup Mode. Out of it, staging them and rebooting achieves nothing, and
    # leaves the ESP signed with keys the firmware rejects once Secure Boot
    # is turned on. So stage only in Setup Mode; otherwise skip, and try
    # again on the next boot. The reboot is an ExecStartPost, which runs only
    # when staging ran and succeeded: lanzaboote's autoReboot is a
    # SuccessAction, which a unit skipped by ExecCondition can still trigger.
    systemd.services.prepare-sb-auto-enroll.serviceConfig = {
      ExecCondition = pkgs.writeShellScript "require-setup-mode" ''
        var=/sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c
        if [ -r "$var" ] && [ "$(${lib.getExe' pkgs.coreutils "od"} -An -tu1 -j4 -N1 "$var" | ${lib.getExe' pkgs.coreutils "tr"} -d ' ')" = 1 ]; then
          exit 0
        fi
        echo "The firmware is not in Setup Mode: not staging Secure Boot keys and not rebooting." \
          "Erase the Secure Boot keys in the BIOS, then boot again." >&2
        exit 1
      '';
      ExecStartPost = "${config.systemd.package}/bin/systemctl --no-block reboot";
    };

    # DMA from devices goes through the IOMMU, translated, with the IOTLB
    # flushed before a page is reused. External Thunderbolt/USB4 devices are
    # then held to their own mappings (bolt authorises them, from
    # profiles.framework); README "Endpoint security" shows how to check that
    # the firmware reports DMA protection.
    boot.kernelParams = [
      "iommu.passthrough=0"
      "iommu.strict=1"
    ];

    # USB devices are blocked unless a rule allows them, including those
    # plugged in before boot. The built-in keyboard (i8042) and touchpad
    # (I2C) are not USB. The expansion card slots are "hotplug" ports, so
    # every card and other device needs a rule downstream
    # (`usbguard generate-policy` prints them). Rules are read-only:
    # `usbguard allow-device` lasts until reboot.
    services.usbguard = {
      enable = true;
      implicitPolicyTarget = "block";
      presentDevicePolicy = "apply-policy";
      insertedDevicePolicy = "apply-policy";
      rules = lib.concatLines [
        # Built-in devices on ports that ACPI marks "hardwired": the webcam
        # module and the MT7925's Bluetooth radio.
        ''allow with-connect-type "hardwired"''
        # Built-in devices on ports that ACPI marks "not used": the
        # fingerprint reader in the power button.
        ''allow with-connect-type "not used"''
      ];
    };

    # The desktop module's 300 s would lock at 305 s.
    home-manager.users.${primaryUser}.idle.short_timeout_duration = lib.mkForce (
      cfg.screenLockSeconds - onIdleLockDelaySeconds
    );

    assertions = [
      {
        assertion =
          config.users.mutableUsers
          && lib.all (o: config.users.users.${primaryUser}.${o} == null) [
            "hashedPassword"
            "hashedPasswordFile"
            "password"
          ];
        message = ''
          The endpoint security baseline keeps ${primaryUser}'s password
          mutable: users.mutableUsers must stay on, with no fixed password
          for ${primaryUser}.
        '';
      }
      # Inbound default-deny: NixOS's firewall drops what no rule opens.
      {
        assertion = config.networking.firewall.enable;
        message = "The endpoint security baseline needs networking.firewall.enable.";
      }
      {
        assertion = config.services.tailscale.enable;
        message = "The endpoint security baseline needs services.tailscale.enable.";
      }
      {
        assertion = config.boot.initrd.luks.devices != { };
        message = "The endpoint security baseline needs the root file system on LUKS.";
      }
      {
        assertion =
          config.dev.johnrinehart.desktop.greetd_niri.hypridle.enable
          && idle.short_timeout_duration + onIdleLockDelaySeconds <= cfg.screenLockSeconds;
        message = ''
          The endpoint security baseline needs hypridle to lock the desktop
          within ${toString cfg.screenLockSeconds} s of idle.
        '';
      }
    ];
  };
}
