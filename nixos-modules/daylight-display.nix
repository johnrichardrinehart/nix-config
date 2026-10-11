{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.desktop.daylightDisplay;
  json = pkgs.formats.json { };
  breakpointType = lib.types.submodule {
    options = {
      event = lib.mkOption {
        type = lib.types.enum [
          "sunrise"
          "sunset"
        ];
        description = "Solar event from which to measure this breakpoint.";
      };
      offsetMinutes = lib.mkOption {
        type = lib.types.int;
        description = "Minutes before (negative) or after the solar event.";
      };
      brightness = lib.mkOption {
        type = lib.types.ints.between 1 100;
        description = "Software display brightness percentage after this breakpoint.";
      };
      temperature = lib.mkOption {
        type = lib.types.ints.between 1000 10000;
        description = "Display color temperature in kelvin after this breakpoint.";
      };
    };
  };
  inherit (import ../lib/daylight-display.nix) breakpoint;
  configFile = json.generate "daylight-display.json" {
    inherit (cfg) breakpoints location;
  };
  daylight-display = pkgs.dev.johnrinehart.daylight-display;
in
{
  options.dev.johnrinehart.desktop.daylightDisplay = {
    enable = lib.mkEnableOption "solar display brightness and color-temperature control";
    location = {
      refreshMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Minutes between live GeoClue location updates.";
      };
      maximumAccuracyMiles = lib.mkOption {
        type = lib.types.ints.positive;
        default = 75;
        description = ''
          Largest GeoClue accuracy radius accepted for solar calculations.
          The last usable result remains cached when a later result is less
          accurate or unavailable.
        '';
      };
      coordinatePrecisionDegrees = lib.mkOption {
        type = lib.types.numbers.positive;
        default = 0.5;
        description = ''
          Precision retained from GeoClue results. Half a degree keeps only a
          rough region while providing solar times well within 20 minutes.
        '';
      };
    };
    breakpoints = lib.mkOption {
      type = lib.types.nonEmptyListOf breakpointType;
      example = lib.literalExpression ''
        let
          breakpoint = inputs.nixosModules.lib.daylightDisplay.breakpoint;
        in
        [
          (breakpoint "sunrise" 45 95 6250)
          (breakpoint "sunset" (-15) 35 3750)
        ]
      '';
      default = [
        (breakpoint "sunrise" (-20) 30 3500)
        (breakpoint "sunrise" (-10) 40 4000)
        (breakpoint "sunrise" 0 50 4500)
        (breakpoint "sunrise" 10 60 5000)
        (breakpoint "sunrise" 20 70 5500)
        (breakpoint "sunrise" 30 80 6000)
        (breakpoint "sunrise" 40 90 6500)
        (breakpoint "sunrise" 50 100 6500)
        (breakpoint "sunset" (-30) 90 6500)
        (breakpoint "sunset" (-20) 80 6000)
        (breakpoint "sunset" (-10) 70 5500)
        (breakpoint "sunset" 0 60 5000)
        (breakpoint "sunset" 10 50 4500)
        (breakpoint "sunset" 20 40 4000)
        (breakpoint "sunset" 30 30 3500)
        (breakpoint "sunset" 40 20 3000)
      ];
      description = ''
        Stepwise brightness and color-temperature settings relative to local
        sunrise or sunset. Each setting remains active until the next
        breakpoint. Consumers can construct entries with the exported
        `lib.daylightDisplay.breakpoint` helper.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ daylight-display ];
    environment.etc."daylight-display.json".source = configFile;

    services.geoclue2 = {
      enable = true;
      appConfig.geoclue-where-am-i = {
        desktopID = "geoclue-where-am-i";
        isAllowed = true;
        isSystem = true;
      };
    };

    systemd.user.services.wl-gammarelay = {
      description = "Wayland display gamma control";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      # Ordering after graphical-session.target forms a cycle with units the
      # target wants (daylight-display), so systemd drops this job at login.
      after = [ "niri.service" ];
      serviceConfig = {
        Type = "dbus";
        BusName = "rs.wl-gammarelay";
        ExecStart = "${lib.getExe pkgs.wl-gammarelay-rs} run";
        Restart = "on-failure";
        RestartSec = "2s";
      };
    };

    systemd.user.services.daylight-display = {
      description = "Set display brightness and color temperature from daylight";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [ "wl-gammarelay.service" ];
      requires = [ "wl-gammarelay.service" ];
      serviceConfig = {
        ExecStart = "${lib.getExe daylight-display} run";
        Restart = "always";
        RestartSec = "2s";
      };
    };
  };
}
