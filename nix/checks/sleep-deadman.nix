# The sleep_deadman module disarms when a hibernation finishes in time and
# panics, then reboots, when it does not. /sys/power/pm_test=freezer stops
# each hibernation once the tasks are frozen, waits 5 s and thaws them: no
# image, no power-off, the same notifier calls. (At the devices level this
# VM's virtio console stops answering after the thaw.)
{ lib, pkgs }:
pkgs.testers.runNixOSTest {
  name = "sleep-deadman";
  globalTimeout = 600;

  nodes.machine = {
    imports = [ ../../nixos-modules/sleep-deadman.nix ];

    # pm_test needs CONFIG_PM_DEBUG, which this kernel has.
    boot.kernelPackages = pkgs.linuxPackages_latest;

    dev.johnrinehart.sleepDeadman = {
      enable = true;
      # Not the module's built-in 300, so the modprobe options are tested too.
      timeoutSeconds = 120;
      rebootSeconds = 1;
    };

    virtualisation.cores = 2;
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed("grep -qw sleep_deadman /proc/modules")
    machine.succeed("echo freezer > /sys/power/pm_test")

    with subtest("a hibernation that finishes in time disarms the deadman"):
        machine.succeed("echo disk > /sys/power/state")
        machine.succeed("dmesg | grep -F 'sleep_deadman: armed for 120 s'")
        machine.succeed("dmesg | grep -F 'sleep_deadman: disarmed'")
        machine.succeed("! dmesg | grep -E 'hibernation hung|sleep_deadman.*deprecated'")

    with subtest("a hibernation that overruns the deadline panics and reboots"):
        # The 5 s pm_test wait overruns a 2 s deadline.
        machine.succeed("echo 2 > /sys/module/sleep_deadman/parameters/timeout_secs")
        machine.execute("(echo disk > /sys/power/state) >/dev/null 2>&1 &")
        machine.wait_for_console_text("sleep_deadman: hibernation did not finish within 2 s")
        machine.wait_for_console_text("Kernel panic - not syncing: sleep_deadman: hibernation hung")
        machine.wait_for_console_text("Rebooting in 1 seconds")
        machine.crash()
  '';
}
