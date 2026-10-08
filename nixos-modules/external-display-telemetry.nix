{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.external-display.telemetry;
  tool = "${pkgs.dev.johnrinehart.display-link-debug}/bin/display-link-debug";
in
{
  options.dev.johnrinehart.external-display.telemetry = {
    enable = lib.mkEnableOption "USB-C/Thunderbolt/DisplayPort diagnostic telemetry";

    verboseKernelLogging = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable DRM debug messages and relevant dynamic-debug callsites from early
        boot. This is intentionally opt-in because it produces a large journal.
      '';
    };

    persistentJournal = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Persist logs across reboot so failed boot and resume sequences remain available.";
    };

    snapshotAfterResume = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Capture a diagnostic bundle after each suspend or hibernate resume.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.dev.johnrinehart.display-link-debug ];
    hardware.i2c.enable = true;

    boot.kernelPatches = [
      {
        name = "external-display-pci-debug-config";
        patch = null;
        structuredExtraConfig = with lib.kernel; {
          PCI_DEBUG = yes;
        };
      }
    ];

    boot.kernelParams = [
      "log_buf_len=32M"
      "printk.time=1"
    ]
    ++ lib.optionals cfg.verboseKernelLogging [
      "drm.debug=0x1ff"
      ''dyndbg="module thunderbolt +p; file drivers/gpu/drm/display/drm_dp_mst_topology.c +p; file drivers/gpu/drm/display/drm_dp_helper.c +p; file drivers/usb/typec/* +p"''
    ];

    services.journald.extraConfig = lib.optionalString cfg.persistentJournal ''
      Storage=persistent
      SystemMaxUse=2G
      MaxRetentionSec=30day
    '';

    systemd.tmpfiles.rules = [
      "d /var/log/display-link-debug 0700 root root -"
    ];

    systemd.services.external-display-verbose-debug = lib.mkIf cfg.verboseKernelLogging {
      description = "Enable runtime USB-C/Thunderbolt/DisplayPort dynamic debugging";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-modules-load.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${tool} dynamic-debug on";
        RemainAfterExit = true;
        ExecStop = "${tool} dynamic-debug off";
      };
    };

    systemd.services.external-display-resume-snapshot = lib.mkIf cfg.snapshotAfterResume {
      description = "Capture external-display state after resume";
      after = [
        "external-display-recovery.service"
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
        "suspend-then-hibernate.target"
      ];
      wantedBy = [
        "suspend.target"
        "hibernate.target"
        "hybrid-sleep.target"
        "suspend-then-hibernate.target"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${tool} snapshot post-resume";
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };

    powerManagement.powerDownCommands = ''
      ${tool} state | ${pkgs.systemd}/bin/systemd-cat -t external-display-pre-sleep
    '';
  };
}
