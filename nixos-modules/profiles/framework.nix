# The desktop and userspace John's Framework laptops share: Framework
# (framie, 11th-gen Intel) and Framework 13 Pro (Ryzen AI 300). Hardware,
# disks, sleep states, and per-host networking and secrets stay with each host.
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.profiles.framework;
  primaryUser = config.dev.johnrinehart.users.primary;
  faceCfg = config.dev.johnrinehart.desktop.greetd_niri.face;
  kittyIntegrationEnabled = config.dev.johnrinehart.users.terminalEmulator.integrations.kitty.enable;
  inherit (import ../../lib/daylight-display.nix) breakpoint;
in
{
  options.dev.johnrinehart.profiles.framework.enable =
    lib.mkEnableOption "the desktop and userspace shared by John's Framework laptops";

  config = lib.mkIf cfg.enable {
    dev.johnrinehart.profiles.laptop.enable = true;

    # Keep the radio available while the Bluetooth keyboard reconnects.
    dev.johnrinehart.bluetooth.autoSuspend.enable = false;

    # Keep a week of redacted HCI history to diagnose keyboard pairing failures.
    dev.johnrinehart.bluetooth.capture = {
      enable = true;
      retention = "7d";
    };

    fonts.fontconfig.enable = lib.mkForce true;

    dev.johnrinehart.desktop = {
      greetd_niri.fingerprint.enable = true;
      # Each host adds its own built-in panel (eDP-1).
      greetd_niri.niri.extraConfig = ''
        debug {
            // Work around Framework/Thunderbolt display resume cases where a docked
            // external monitor remains DRM-connected but disabled and missing from
            // `niri msg outputs`.
            force-disable-connectors-on-resume
        }
        output "Dell Inc. DELL U3225QE 6WS9B84" {
            mode "3840x2160@59.997"
            position x=0 y=0
            scale 1.0
        }
        output "Dell Inc. DELL U2520D 7Z4V823" {
            position x=3840 y=360
        }
      '';
      greetd_niri.niri.extraKeybindings = ''
        Mod+O repeat=false {
            toggle-overview all-outputs=false
        }
        Mod+Shift+O repeat=false {
            toggle-overview
        }
      '';
      daylightDisplay = {
        enable = true;
        breakpoints = [
          (breakpoint "sunrise" (-30) 60 3500)
          (breakpoint "sunrise" (-25) 63 3750)
          (breakpoint "sunrise" (-20) 67 4000)
          (breakpoint "sunrise" (-15) 70 4250)
          (breakpoint "sunrise" (-10) 73 4500)
          (breakpoint "sunrise" (-5) 77 4750)
          (breakpoint "sunrise" 0 80 5000)
          (breakpoint "sunrise" 5 83 5250)
          (breakpoint "sunrise" 10 87 5500)
          (breakpoint "sunrise" 15 90 5750)
          (breakpoint "sunrise" 20 93 6000)
          (breakpoint "sunrise" 25 97 6250)
          (breakpoint "sunrise" 30 100 6500)
          (breakpoint "sunset" (-30) 100 6500)
          (breakpoint "sunset" (-25) 97 6250)
          (breakpoint "sunset" (-20) 93 6000)
          (breakpoint "sunset" (-15) 90 5750)
          (breakpoint "sunset" (-10) 87 5500)
          (breakpoint "sunset" (-5) 83 5250)
          (breakpoint "sunset" 0 80 5000)
          (breakpoint "sunset" 5 77 4750)
          (breakpoint "sunset" 10 73 4500)
          (breakpoint "sunset" 15 70 4250)
          (breakpoint "sunset" 20 67 4000)
          (breakpoint "sunset" 25 63 3750)
          (breakpoint "sunset" 30 60 3500)
        ];
      };
    };

    # Authenticate before starting Niri so PAM receives the login password and
    # can unlock GNOME Keyring before applications such as Brave are launched.
    # The shared desktop module otherwise starts Niri directly as greetd's
    # unauthenticated default session. The console sends Super as Alt, so
    # Super+Alt+F arrives as Alt+F. The patched tuigreet then starts a face
    # scan for the user.
    services.greetd = {
      useTextGreeter = true;
      settings.default_session = {
        command = lib.mkForce (
          "${lib.getExe pkgs.dev.johnrinehart.tuigreet} --time --remember --user-menu --asterisks --cmd ${lib.getExe' config.programs.niri.package "niri-session"}"
          + lib.optionalString faceCfg.enable " --biometric-cmd '${lib.getExe config.services.pam-biometrics.package} face scan'"
        );
        user = lib.mkForce "greeter";
      };
    };

    # greetd starts its default greeter through this PAM service without running
    # authentication. Define the account/session phases explicitly; otherwise
    # Linux-PAM falls back to the deny-all `other` service and tuigreet cannot
    # start after reboot.
    security.pam.services.greetd-greeter.text = ''
      auth required pam_permit.so
      account required pam_permit.so
      password required pam_deny.so
      session required pam_env.so conffile=/etc/pam/environment readenv=0
      session required pam_unix.so
      session optional ${pkgs.systemd}/lib/security/pam_systemd.so
    '';
    dev.johnrinehart.voice-dictation.enable = true;
    dev.johnrinehart.kitkat-rs.variant = "faster";

    dev.johnrinehart.droidcam.enable = false; # TODO: broken
    dev.johnrinehart.programs.git.meld.enable = true;

    home-manager.users.${primaryUser} = lib.mkIf kittyIntegrationEnabled {
      programs.kitty.extraConfig = lib.mkAfter ''
        mouse_map ctrl+left release grabbed,ungrabbed mouse_handle_click link
      '';
      xdg.configFile."kitty/open-actions.conf".text = ''
        protocol http,https
        action launch --type=background ${lib.getExe' pkgs.wl-clipboard "wl-copy"} -- $URL
      '';
    };

    programs.ssh.extraConfig = lib.mkAfter ''
      Host keepass.johnrinehart.dev
        Port 2222
    '';

    dev.johnrinehart.auto-suspend = {
      lowLevel = 30;
      criticalLevel = 20;
      notificationLevels = builtins.genList (i: 45 - (i * 5)) 6; # [ 45 40 35 30 25 20 ]
      enable = true;
    };

    nix = {
      settings = {
        extra-experimental-features = "nix-command flakes ca-derivations";
        download-buffer-size = 256 * 1024 * 1024;
        keep-outputs = true;
        min-free = 5 * 1024 * 1024 * 1024;
        max-free = 10 * 1024 * 1024 * 1024;
      };
    };

    boot.supportedFilesystems = [
      "ntfs"
      "exfat"
      "vfat"
      "btrfs"
      "ext"
    ];

    hardware.enableRedistributableFirmware = true;

    services.fwupd.enable = true;

    security.rtkit.enable = true;

    ## Below v4l2loopback stuff stolen from https://gist.github.com/TheSirC/93130f70cc280cdcdff89faf8d4e98ab
    # Extra kernel modules
    boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;
    boot.extraModulePackages = [ config.boot.kernelPackages.v4l2loopback ];

    environment.etc."modprobe.d/v4l2loopback.conf".text = ''
      options v4l2loopback video_nr=0,1,2 card_label="Virtual Video 0,Virtual Video 1,Virtual Video 2" exclusive_caps=1
    '';

    environment.etc."modules-load.d/v4l2loopback.conf".text = ''
      v4l2loopback
    '';

    services.chrony = {
      enable = true;
      # if we're off by >1s then jump system clock only within the 1st 3 clock
      # updates
      extraConfig = ''
        makestep 1 3
      '';
    };

    networking.timeServers = options.networking.timeServers.default ++ [ "time.facebook.com" ];

    services.upower = {
      enable = true;
    };

    services.getty.loginOptions = "-- \\u TMOUT=10";

    # Each host ranks its own built-in microphone with more inputRules.
    dev.johnrinehart.sound = {
      enable = true;

      # Use the Samson Q9U's zero-latency hardware direct monitor without also
      # routing the processed microphone back through PipeWire.
      softwareMicMonitor.enable = false;

      rnnoise = {
        highpass = {
          enable = true;
          frequency = 210.0;
        };
        dualMonoOutput.enable = true;
        vadThreshold = 70.0;
        vadGracePeriod = 300.0;
        retroactiveVadGrace = 100.0;
        # RNNoise provides best-effort keyboard attenuation without the
        # real-time underruns caused by the heavier DeepFilterNet stage.
        deepfilter.enable = false;
        inputRules = [
          {
            matches = [
              {
                "media.class" = "Audio/Source";
                "api.alsa.card.name" = "Samson Q9U";
              }
            ];
            actions.update-props = {
              "priority.session" = 2300;
            };
          }
        ];
      };
    };

    hardware.keyboard.zsa.enable = true;

    services.hardware.bolt.enable = true;
  };
}
