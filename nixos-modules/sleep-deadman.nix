# Panic, and so reboot, when a hibernation hangs, keeping its kernel log.
#
# A hibernation that blocks once user space is frozen wedges the machine:
# the screen stays dark, nothing reaches the journal, no image is written,
# and it runs until someone holds the power button or the battery is empty.
# The next boot cannot resume ("PM: Image not found"), so the session is
# lost either way. The kernel's hung task detector is off for exactly this
# window.
#
# The sleep_deadman module (packages/sleep-deadman) arms a timer when a
# hibernation starts and disarms it once the machine is back. If the
# hibernation takes longer than timeoutSeconds, it prints the stack of
# every blocked task and panics. The EFI pstore backend keeps the end of
# the kernel log, which systemd-pstore copies to /var/lib/systemd/pstore on
# the next boot, and the machine reboots rebootSeconds after the panic.
# Only that panic reboots: kernel.panic is not changed.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.sleepDeadman;
in
{
  options.dev.johnrinehart.sleepDeadman = {
    enable = lib.mkEnableOption "a panic and reboot, with the blocked tasks in pstore, when a hibernation hangs";

    timeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = ''
        Longest a hibernation may take, from its start until the machine
        powers off, or after a resume until its devices are back.
      '';
    };

    rebootSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Seconds from the panic to the reboot.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.extraModulePackages = [
      (pkgs.dev.johnrinehart.sleep-deadman.override {
        inherit (config.boot.kernelPackages) kernel kernelModuleMakeFlags;
      })
    ];
    boot.kernelModules = [ "sleep_deadman" ];
    boot.extraModprobeConfig = ''
      options sleep_deadman timeout_secs=${toString cfg.timeoutSeconds} reboot_secs=${toString cfg.rebootSeconds}
    '';
  };
}
