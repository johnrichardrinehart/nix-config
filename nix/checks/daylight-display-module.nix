{
  inputs,
  lib,
  pkgs,
}:
let
  inherit (inputs.self.lib.daylightDisplay) breakpoint;
  customBreakpoints = [
    (breakpoint "sunrise" 45 95 6250)
    (breakpoint "sunset" (-15) 35 3750)
  ];
  evaluated = lib.nixosSystem {
    specialArgs = { inherit inputs; };
    modules = [
      (import ../../nixos-modules { inherit inputs lib; })
      {
        nixpkgs.hostPlatform = "x86_64-linux";
        nixpkgs.overlays = [ (import ../../overlays inputs).default ];
        system.stateVersion = "24.05";

        dev.johnrinehart.desktop.daylightDisplay = {
          enable = true;
          breakpoints = customBreakpoints;
        };
      }
    ];
  };
  cfg = evaluated.config;
  service = cfg.systemd.user.services.daylight-display;
in
assert cfg.dev.johnrinehart.desktop.daylightDisplay.breakpoints == customBreakpoints;
assert
  builtins.head customBreakpoints == {
    event = "sunrise";
    offsetMinutes = 45;
    brightness = 95;
    temperature = 6250;
  };
assert service.serviceConfig.ExecStart != null;
assert cfg.systemd.user.services.wl-gammarelay.serviceConfig.ExecStart != null;
assert builtins.elem pkgs.dev.johnrinehart.daylight-display cfg.environment.systemPackages;
pkgs.runCommand "daylight-display-module-evaluation" { } ''
  export PYTHONDONTWRITEBYTECODE=1
  export PYTHONPATH=${../../packages/daylight-display}
  ${lib.getExe pkgs.python3} ${../../packages/daylight-display/test_daylight_display.py}
  touch $out
''
