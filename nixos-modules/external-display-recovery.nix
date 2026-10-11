{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.external-display.recovery;
  tool = "${pkgs.dev.johnrinehart.display-link-debug}/bin/display-link-debug";
  shellList = values: lib.concatMapStringsSep " " lib.escapeShellArg values;
  recoveryCommand = pkgs.writeShellScript "external-display-recovery" ''
    status=0
    ${tool} repair ${toString cfg.attempts} ${toString cfg.delaySeconds} ${toString cfg.minimumExternalConnectors} ${lib.optionalString cfg.reprobeControllers "reprobe"} || status=$?
    ${lib.optionalString cfg.snapshotOnFailure ''
      if (( status != 0 )); then
        ${tool} snapshot automatic-recovery-failure || true
      fi
    ''}
    exit "$status"
  '';
  applyPowerPolicy = pkgs.writeShellScript "external-display-power-policy" ''
    set -u
    for address in ${shellList cfg.powerManagement.pciDevices}; do
      device="/sys/bus/pci/devices/$address"
      if [[ ! -e "$device" ]]; then
        echo "external-display-power-policy: $address is not present" >&2
        continue
      fi
      ${lib.optionalString cfg.powerManagement.preventD3Cold ''
        if [[ -w "$device/d3cold_allowed" ]]; then
          printf '0\n' > "$device/d3cold_allowed"
        fi
      ''}
      ${lib.optionalString cfg.powerManagement.disableRuntimeSuspend ''
        if [[ -w "$device/power/control" ]]; then
          printf 'on\n' > "$device/power/control"
        fi
      ''}
    done
  '';
in
{
  options.dev.johnrinehart.external-display.recovery = {
    enable = lib.mkEnableOption "bounded USB-C/Thunderbolt DisplayPort recovery retries";

    attempts = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
      description = "Maximum number of Thunderbolt domain rescans per recovery run.";
    };

    delaySeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Delay between recovery attempts.";
    };

    minimumExternalConnectors = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Number of connected external DRM connectors with modes and EDIDs required before recovery succeeds.";
    };

    snapshotOnFailure = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Automatically capture a diagnostic bundle when all recovery attempts fail.";
    };

    onHotplug = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Request a debounced recovery run after Thunderbolt device hotplug.";
    };

    onResume = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run bounded recovery after suspend and hibernate resume.";
    };

    reprobeControllers = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Re-probe only an NHI whose ICM rescan fails because its control channel is unavailable.";
    };

    quiesceStuckUsbPorts = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Disable root-hub ports stuck in device enumeration before sleep and restore them after resume.";
    };

    powerManagement = {
      pciDevices = lib.mkOption {
        type = lib.types.listOf (
          lib.types.strMatching "[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\\.[[:xdigit:]]"
        );
        default = [ ];
        example = [
          "0000:00:07.0"
          "0000:00:0d.2"
        ];
        description = ''
          Explicit PCI addresses for USB-C/Thunderbolt root ports, NHI, or xHCI
          functions whose power policy should be changed. Explicit selection
          avoids weakening power management for unrelated PCI devices.
        '';
      };

      preventD3Cold = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Set d3cold_allowed=0 on the selected PCI devices at boot and after resume.";
      };

      disableRuntimeSuspend = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Set power/control=on on the selected PCI devices at boot and after resume.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          !(cfg.powerManagement.preventD3Cold || cfg.powerManagement.disableRuntimeSuspend)
          || cfg.powerManagement.pciDevices != [ ];
        message = "external-display recovery power workarounds require explicit powerManagement.pciDevices";
      }
    ];

    environment.systemPackages = [ pkgs.dev.johnrinehart.display-link-debug ];

    powerManagement.powerDownCommands = lib.optionalString cfg.quiesceStuckUsbPorts ''
      ${tool} quiesce-usb-ports
    '';
    powerManagement.resumeCommands = lib.optionalString cfg.quiesceStuckUsbPorts ''
      ${tool} restore-usb-ports
    '';

    services.udev.extraRules = lib.optionalString cfg.onHotplug ''
      ACTION=="add|change", SUBSYSTEM=="thunderbolt", TAG+="systemd", ENV{SYSTEMD_WANTS}+="external-display-recovery.service"
      ACTION=="change", SUBSYSTEM=="drm", KERNEL=="card*-DP-*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="external-display-recovery.service"
    '';

    systemd.services.external-display-power-policy = {
      description = "Apply selected USB-C/Thunderbolt PCI power policy";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-modules-load.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = applyPowerPolicy;
        RemainAfterExit = true;
      };
    };

    systemd.services.external-display-recovery = {
      description = "Retry USB-C/Thunderbolt DisplayPort discovery";
      after = [
        "systemd-udev-settle.service"
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
        "suspend-then-hibernate.target"
      ];
      wants = [ "systemd-udev-settle.service" ];
      wantedBy = lib.optionals cfg.onResume [
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
        "suspend-then-hibernate.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStartPre = applyPowerPolicy;
        ExecStart = recoveryCommand;
        SuccessExitStatus = [ 1 ];
        # Recovery runs udev settles after each rescan. Failure snapshots also
        # probe every DDC bus, so the timeout must include both operations.
        TimeoutStartSec = "5min";
      };
    };
  };
}
