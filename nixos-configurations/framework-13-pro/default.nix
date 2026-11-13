# The Framework 13 Pro installed on its NVMe drive, as `install-to-disk`
# (framework-13-pro-netboot) lays it out: disko.nix. It boots with Secure
# Boot under the endpoint security baseline: endpoint-security.nix.
{
  config,
  inputs,
  lib,
  ...
}:
let
  initrdRootHashedPassword = config.dev.johnrinehart.endpointSecurity.initrdRootHashedPassword;
in
{
  imports = [
    inputs.disko.nixosModules.disko
    ./common.nix
    ./disko.nix
    ./endpoint-security.nix
  ];

  # The boot menu editor is off (endpoint-security.nix), so stage 1 cannot
  # be stopped by typing at the menu. With root locked in the initrd the
  # maintenance shell cannot be opened, so the entry exists only once
  # initrdRootHashedPassword is set.
  dev.johnrinehart.maintenanceInitrd = lib.mkIf (initrdRootHashedPassword != null) {
    enable = true;
    emergencyAccess = initrdRootHashedPassword;
    # Its firmware comes along (modinfo).
    wifiKernelModules = [ "mt7925e" ];
  };

  # Super+Alt+F, the face and a YubiKey touch open the LUKS root, while the
  # TPM sees this Secure Boot state (PCR 7). `luks-fido-face-enroll` sets it
  # up; the passphrase keeps working.
  dev.johnrinehart.luksFidoFace = {
    enable = true;
    # The Framework Laptop Webcam Module (2nd Gen).
    cameraUsbId = "32ac:001c";
  };

  # 96 GiB of swap, a file inside the LUKS root, so a hibernation image of
  # all 93 GiB of RAM fits. systemd writes the file's location (device and
  # offset) to the HibernateLocation EFI variable when it hibernates and
  # stage 1 resumes from it: no resume= or resume_offset= to keep in sync.
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 96 * 1024;
    }
  ];
  boot.kernelParams = [
    # The hibernation image is compressed with LZ4 instead of LZO: faster to
    # write and to read back, a little larger. Built into the kernel, so
    # stage 1 can decompress it.
    "hibernate.compressor=lz4"
    # Swapped pages are compressed in RAM (zswap, LZ4) before they reach
    # the swap file.
    "zswap.enabled=1"
    "zswap.compressor=lz4"
    # The image lives on the LUKS root, which appears only once it is
    # unlocked. For a location from HibernateLocation, stage 1 waits just
    # 2 minutes for that device and then boots without resuming; this makes
    # it wait for the unlock however long it takes.
    "resumeflags=x-systemd.device-timeout=infinity"
  ];
  dev.johnrinehart.system.suspendVerb = "suspend-then-hibernate";
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend-then-hibernate";
    HandlePowerKey = "suspend-then-hibernate";
    HandleSuspendKey = "suspend-then-hibernate";
  };

  boot.loader.efi.canTouchEfiVariables = true;

  # Stage 1 unlocks the LUKS root on the NVMe drive, with a USB keyboard
  # or through a dock if need be.
  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "thunderbolt"
    "usbhid"
    "usb_storage"
    "uas"
    "sd_mod"
  ];
}
