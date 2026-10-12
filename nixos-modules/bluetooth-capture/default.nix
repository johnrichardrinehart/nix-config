{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.bluetooth.capture;
  directory = "/var/log/btmon";

  # The build fails if the filter lets a key, passkey, PIN, or HID report
  # through btmon's output for the BlueZ version in use.
  btmonFilter =
    pkgs.runCommand "btmon-filter"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 ${./test_btmon_filter.py} ${pkgs.bluez}/bin/btmon ${./btmon_filter.py}
        install -Dm444 ${./btmon_filter.py} $out/lib/btmon_filter.py
      '';

  capture = pkgs.writeShellScript "bluetooth-capture" ''
    set -o pipefail
    ${pkgs.coreutils}/bin/stdbuf -oL ${pkgs.bluez}/bin/btmon --date --columns=250 --color=never \
      | ${pkgs.python3}/bin/python3 ${btmonFilter}/lib/btmon_filter.py --output-dir ${directory}
  '';
in
{
  options.dev.johnrinehart.bluetooth.capture = {
    enable = lib.mkEnableOption ''
      a continuous Bluetooth HCI capture in ${directory}. The capture keeps
      commands, events, and management messages, one file per UTC hour. It
      drops all data packets, which carry keystrokes, and redacts key material
    '';

    retention = lib.mkOption {
      type = lib.types.str;
      example = "7d";
      description = ''
        Age after which systemd-tmpfiles deletes capture files, in
        systemd.time(7) format.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d ${directory} 0700 root root ${cfg.retention}" ];

    systemd.services.bluetooth-capture = {
      description = "Capture Bluetooth HCI traffic without data packets or keys";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      serviceConfig = {
        ExecStart = capture;
        Restart = "always";
        RestartSec = 5;
        # The HCI monitor channel requires CAP_NET_RAW.
        CapabilityBoundingSet = [ "CAP_NET_RAW" ];
        AmbientCapabilities = [ "CAP_NET_RAW" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ directory ];
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictAddressFamilies = [
          "AF_BLUETOOTH"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        UMask = "0077";
      };
    };
  };
}
