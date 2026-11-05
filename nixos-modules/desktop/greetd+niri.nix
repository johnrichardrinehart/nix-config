{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.desktop.greetd_niri;
  primaryUser = config.dev.johnrinehart.users.primary;
  terminalEmulator = config.dev.johnrinehart.users.terminalEmulator.package;

  # Cursor theme settings (single source of truth)
  xcursorTheme = "Adwaita";
  xcursorSize = 24;

  indentKdlLines =
    prefix: text:
    lib.concatStringsSep "\n" (
      map (line: if line == "" then "" else "${prefix}${line}") (lib.splitString "\n" text)
    );

  wormhole-send = pkgs.dev.johnrinehart.wormhole-send;
  display-layout = pkgs.dev.johnrinehart.display-layout;
  focus-or-spawn = pkgs.dev.johnrinehart.focus-or-spawn.override {
    niri = config.programs.niri.package;
  };

  niriRevision = "a8562a1126922ed4c1c94d34c1dbb26633491d05";
  niriSource = pkgs.fetchFromGitHub {
    owner = "niri-wm";
    repo = "niri";
    rev = niriRevision;
    hash = "sha256-AtuZOzsb9p+TTzkgaPjvl+5YRsgKc+RlIQMyozOmY5A=";
  };
  niriPatches = [
    ./0000-version-report-downstream-patches.patch
    ./0001-overview-allow-targeting-active-output.patch
    ./0002-screencast-accept-remote-desktop-sessions.patch
    ./0003-niri-pin-smithay-master.patch
    ./0004-input-support-per-device-keyboard-settings.patch
  ];
  niriPatchVersionSuffix = lib.concatMapStrings (
    patch: "\n+ ${builtins.baseNameOf (toString patch)}"
  ) niriPatches;
  # Niri 26.04 predates Smithay's SHM damage fix and does not compile with current Smithay APIs.
  # Follow Niri main for compatible APIs, then pin Smithay to the current upstream master tip.
  # Keep smithay-drm-extras on the fork containing the unmerged late-CRTC mapping fix
  # (Smithay/smithay#2125).
  niriPatched = pkgs.niri.overrideAttrs (old: {
    src = niriSource;
    patches = (old.patches or [ ]) ++ niriPatches;

    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      name = "${old.pname}-${old.version}";
      src = niriSource;
      patches = (old.cargoPatches or [ ]) ++ niriPatches;
      hash = "sha256-eJ2pb8ZvLpoisGp1+aSAdi0O6536wR2Ox8VCZVIcGIc=";
    };
    env = (old.env or { }) // {
      NIRI_BUILD_COMMIT = niriRevision;
      NIRI_BUILD_PATCHES = niriPatchVersionSuffix;
    };
  });

  niri-screenshot = pkgs.dev.johnrinehart.niri-screenshot.override {
    niri = config.programs.niri.package;
    inherit wormhole-send;
  };

  inherit (pkgs.dev.johnrinehart)
    brightness-notify
    keyboard-brightness-notify
    volume-notify
    ;
  input-toggle-notify = pkgs.dev.johnrinehart.input-toggle-notify.override {
    niri = config.programs.niri.package;
  };
  monitor-power-notify = pkgs.dev.johnrinehart.monitor-power-notify.override {
    niri = config.programs.niri.package;
  };

  niri-cycle-display-mode = pkgs.dev.johnrinehart.niri-cycle-display-mode.override {
    niri = config.programs.niri.package;
  };
  niri-remote-desktop = pkgs.dev.johnrinehart.niri-remote-desktop.override {
    niri = config.programs.niri.package;
  };

  clipboard-store-notify = pkgs.dev.johnrinehart.clipboard-store-notify;
  clipboard-watch = pkgs.dev.johnrinehart.clipboard-watch.override {
    inherit clipboard-store-notify;
  };
  cliphist-picker = pkgs.dev.johnrinehart.cliphist-picker.override {
    niri = config.programs.niri.package;
  };

  # Wallpaper, served by awww. The daemon creates surfaces for hotplugged
  # outputs, but initializes them to black rather than inheriting the current
  # image. Keep a small watcher beside it that applies the configured image to
  # every newly created surface.
  #
  # The source image is huge (7952x5304); awww decodes it into per-output
  # buffer pools, so we pre-scale it down to 4K to keep the daemon's resident
  # memory modest instead of ~170MB.
  wallpaper = pkgs.runCommand "wallpaper-scaled.jpg" { nativeBuildInputs = [ pkgs.imagemagick ]; } ''
    magick ${../../static/full-moon-forest-night-dark-starry-sky-5k-8k-7952x5304-1684.jpg} \
      -resize 3840x2160^ -quality 92 $out
  '';

  # Keep the shell as a tiny supervisor so the watcher cannot outlive the
  # daemon, and exit with it so the user unit below restarts both. Polling the
  # daemon's own state avoids connector-name assumptions and covers hotplug,
  # MST renumbering, and resume without relying on niri's event-stream format.
  awww-wallpaper = pkgs.writeShellScript "awww-wallpaper" ''
    set -u
    awww="${lib.getExe' pkgs.awww "awww"}"
    daemon="${lib.getExe' pkgs.awww "awww-daemon"}"
    jq="${lib.getExe pkgs.jq}"

    "$daemon" &
    daemon_pid=$!
    trap 'kill "$daemon_pid" 2>/dev/null || true' EXIT INT TERM

    while kill -0 "$daemon_pid" 2>/dev/null; do
      missing=$(
        "$awww" query --json 2>/dev/null \
          | "$jq" -r '[.[][] | select(.displaying.color? != null) | .name] | join(",")'
      ) || missing=""

      if [[ -n $missing ]]; then
        "$awww" img \
          --outputs "$missing" \
          --resize crop \
          --transition-type none \
          ${wallpaper} >/dev/null 2>&1 || true
      fi
      sleep 1
    done

    wait "$daemon_pid"
  '';

  biometrics = config.services.pam-biometrics;

  # Mod+Alt+F starts a face scan for any password prompt in the session: sudo,
  # polkit, and hyprlock. Niri runs it on the lock screen too. SIGUSR2 makes
  # hyprlock refresh the face status label.
  face-scan-key = pkgs.writeShellApplication {
    name = "face-scan-key";
    runtimeInputs = [
      biometrics.package
      pkgs.procps
    ];
    text = ''
      refresh() { pkill -USR2 -u "$UID" -x hyprlock || true; }
      pam-biometrics face scan >/dev/null || true
      refresh
      pam-biometrics face wait >/dev/null
      refresh
    '';
  };
  faceScanKeybinding = ''
    Mod+Alt+F allow-when-locked=true hotkey-overlay-title="Scan Face for Authentication" {
        spawn "${lib.getExe face-scan-key}"
    }
  '';

  # Shared PAM configuration for password authentication with optional
  # fingerprint and face factors. The password is always required.
  #
  # Without the face check, the fingerprint comes first and can only reject an
  # attempt.
  #
  # With the face check, every service runs the same auth flow. pam_biometrics
  # start claims the fingerprint reader and asks for the password; an empty
  # answer (the configured trigger) scans the face first. pam_unix checks the
  # password the user just typed, so the keyring still gets a fresh one.
  # pam_biometrics finish takes a finger or face from before or during the
  # password, or offers one afterwards when the policy needs it, and applies
  # /etc/pam-biometrics/policy.json: a wrong finger or another face rejects the
  # attempt.
  fingerprintPamRule = ''
    # Fingerprint: success→continue, timeout/unavailable→continue, wrong→reject immediately
    auth [success=ok ignore=ignore authinfo_unavail=ignore default=die] ${pkgs.fprintd}/lib/security/pam_fprintd.so timeout=${toString cfg.fingerprint.timeoutSeconds}
  '';
  biometricAuth = ''
    ${biometrics.pamRules.start}
    auth requisite pam_unix.so nullok try_first_pass
    ${biometrics.pamRules.finish}
  '';
  authPamConfig =
    if cfg.face.enable then
      ''
        # Account management
        account required pam_unix.so

        # Authentication management
        ${biometricAuth}
        ${commonPamConfig}
      ''
    else
      ''
        # Account management
        account required pam_unix.so

        # Authentication management
        ${lib.optionalString cfg.fingerprint.enable fingerprintPamRule}
        # Password is always required (do NOT use try_first_pass - we need fresh password for keyring)
        auth required pam_unix.so nullok
        ${commonPamConfig}
      '';
  # su and vlock switch or lock an existing session, so they keep their own
  # session lines (no loginuid, no logind session) around the shared auth.
  ownSessionPamConfig =
    {
      authFirst ? "",
      session,
    }:
    ''
      account required pam_unix.so

      ${authFirst}
      ${biometricAuth}

      password sufficient pam_unix.so nullok yescrypt

      session required pam_env.so conffile=/etc/pam/environment readenv=0
      session required pam_unix.so
      ${session}
      session required pam_limits.so
    '';
  commonPamConfig = ''
    auth optional ${pkgs.gnome-keyring}/lib/security/pam_gnome_keyring.so

    # Password management
    password sufficient pam_unix.so nullok yescrypt
    password optional ${pkgs.gnome-keyring}/lib/security/pam_gnome_keyring.so use_authtok

    # Session management
    session required pam_env.so conffile=/etc/pam/environment readenv=0
    session required pam_unix.so
    session required pam_loginuid.so
    session optional ${pkgs.systemd}/lib/security/pam_systemd.so
    session required pam_limits.so
    session optional ${pkgs.gnome-keyring}/lib/security/pam_gnome_keyring.so auto_start
  '';
in
{
  imports = [ inputs.pam-biometrics.nixosModules.default ];

  options = {
    dev.johnrinehart.desktop.greetd_niri = {
      enable = lib.mkEnableOption "greetd + niri";
      hypridle.enable = lib.mkEnableOption "hypridle integration" // {
        default = true;
      };
      fingerprint = {
        enable = lib.mkEnableOption "fingerprint authentication";
        timeoutSeconds = lib.mkOption {
          type = lib.types.ints.positive;
          default = 15;
          description = "Seconds to wait for a fingerprint, or for a fingerprint or face with the face check, before timing out.";
        };
      };
      face = {
        enable = lib.mkEnableOption ''
          a webcam face check for every password prompt through pam-biometrics.
          Super+Alt+F starts a scan. A fingerprint or a face satisfies the
          biometric step. A password is always required'';
        device = lib.mkOption {
          type = lib.types.str;
          example = "/dev/v4l/by-id/usb-Generic_Laptop_Camera_200901010001-video-index0";
          description = "V4L2 capture device of the webcam.";
        };
        inputFormat = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "mjpeg";
          description = ''
            V4L2 input format to request at 640x360. Null lets ffmpeg use the
            current format of the device.
          '';
        };
      };
      niri = {
        extraConfig = lib.mkOption {
          type = lib.types.lines;
          default = "";
          example = ''
            window-rule {
                match app-id="^org.example.App$"
                open-floating true
            }
          '';
          description = ''
            Extra raw KDL configuration appended to the generated niri
            configuration as top-level entries.
          '';
        };
        extraKeybindings = lib.mkOption {
          type = lib.types.lines;
          default = ''
            Mod+O repeat=false {
                toggle-overview
            }
          '';
          example = ''
            Mod+Shift+Return {
                spawn "alacritty"
            }
          '';
          description = ''
            Raw KDL keybindings inserted inside the generated niri binds
            block. A downstream definition replaces the default bindings.
          '';
        };
        displayModeWatch.enable = lib.mkEnableOption "automatic Niri display-mode recovery" // {
          default = true;
        };
      };
      waybar = {
        systemd.enable = lib.mkEnableOption "Waybar systemd service";
        connectivityInterfacePattern = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "wlp*";
          description = ''
            Interface pattern passed to Waybar's network module for the
            connectivity section. Leave null to let Waybar choose the active
            interface automatically.
          '';
        };
      };
    };

    # services.fprintd.enable makes nixpkgs add `auth sufficient pam_fprintd`
    # to every PAM service, so a finger alone passed su, run0, passwd, chsh
    # and the rest without a password. Fingerprints count only where
    # authPamConfig places pam_biometrics, before or after the password, which
    # stays required; elsewhere the password alone decides. A service can still
    # opt in with fprintAuth = true.
    security.pam.services = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          config.fprintAuth = lib.mkIf cfg.enable (lib.mkDefault false);
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    environment.sessionVariables = {
      NIXOS_OZONE_WL = "1";
      XCURSOR_THEME = xcursorTheme;
      XCURSOR_SIZE = toString xcursorSize;
      # Qt apps (KeePassXC, OBS) otherwise draw their own file dialog instead
      # of asking the portal below. qtbase ships this platform theme plugin.
      QT_QPA_PLATFORMTHEME = "xdgdesktopportal";
    };

    programs.niri.enable = true;

    # Use Nautilus through the GNOME portal for file chooser grid view.
    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-gnome ];
      config.niri."org.freedesktop.impl.portal.FileChooser" = "gnome";
    };

    # kitty's entry claims inode/directory, and with no default set it wins,
    # so "open containing folder" opened a terminal.
    xdg.mime.defaultApplications."inode/directory" = "org.gnome.Nautilus.desktop";

    # nixpkgs' niri with the downstream patches above and pinned Smithay sources.
    # Every niri consumer here and in home-manager reads this option, so a
    # host that sets programs.niri.package swaps the build everywhere.
    programs.niri.package = lib.mkDefault niriPatched;

    users.users.${primaryUser}.extraGroups = [ "seat" ];

    services.greetd.enable = true;
    services.fprintd.enable = lib.mkIf cfg.fingerprint.enable true;
    # Raise the fd soft limit so children (waybar, etc.) don't hit the
    # default 1024 and fail with "Too many open files" on boot.
    systemd.services.greetd.serviceConfig.LimitNOFILE = "524288";
    # Authenticate before starting Niri so PAM receives the login password and
    # can unlock GNOME Keyring before applications such as Brave are launched.
    # The console sends Super as Alt, so Super+Alt+F arrives as Alt+F. The
    # patched tuigreet then starts a face scan for the user.
    services.greetd.useTextGreeter = true;
    services.greetd.settings.default_session = {
      command =
        "${lib.getExe pkgs.dev.johnrinehart.tuigreet} --time --remember --user-menu --asterisks --cmd ${lib.getExe' config.programs.niri.package "niri-session"}"
        + lib.optionalString cfg.face.enable " --biometric-cmd '${lib.getExe config.services.pam-biometrics.package} face scan'";
      user = "greeter";
    };

    systemd.user.services.waybar = lib.mkIf cfg.waybar.systemd.enable {
      description = "Wayland bar";
      wantedBy = [ "niri.service" ];
      wants = [ "pipewire-pulse.service" ];
      after = [
        "niri.service"
        "pipewire-pulse.service"
      ];
      partOf = [ "graphical-session.target" ];
      requisite = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = lib.getExe pkgs.waybar;
        Restart = "on-failure";
        RestartSec = "1s";
      };
    };

    systemd.user.services.niri-remote-desktop = {
      description = "Expose authorized remote pointer motion to the Niri portal";
      wantedBy = [ "graphical-session.target" ];
      after = [ "niri.service" ];
      partOf = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = lib.getExe niri-remote-desktop;
        Restart = "on-failure";
        RestartSec = 1;
      };
    };

    systemd.user.services.niri-display-mode-watch = lib.mkIf cfg.niri.displayModeWatch.enable {
      description = "Keep niri display mode recoverable after output disconnects";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      after = [
        "niri.service"
        "graphical-session.target"
      ];
      serviceConfig = {
        ExecStart = "${lib.getExe niri-cycle-display-mode} --watch";
        Restart = "always";
        RestartSec = "1s";
      };
    };

    # A spawn-at-startup child is never restarted, so one daemon exit left the
    # session without a wallpaper until the next login.
    systemd.user.services.awww-wallpaper = {
      description = "Wallpaper (awww)";
      wantedBy = [ "niri.service" ];
      bindsTo = [ "niri.service" ];
      # awww-daemon restores its cached image through `sh -c "exec awww img …"`.
      path = [ pkgs.awww ];
      after = [ "niri.service" ];
      serviceConfig = {
        ExecStart = awww-wallpaper;
        Restart = "always";
        RestartSec = "1s";
      };
    };

    environment.systemPackages =
      let
        myMako = pkgs.dev.johnrinehart.mako-with-etc-config;
        niri-gather-windows = pkgs.dev.johnrinehart.niri-gather-windows.override {
          niri = config.programs.niri.package;
        };
      in
      [
        display-layout
        focus-or-spawn
        niri-gather-windows
        niri-cycle-display-mode
        niri-screenshot
        brightness-notify
        input-toggle-notify
        keyboard-brightness-notify
        monitor-power-notify
        volume-notify
        wormhole-send
        pkgs.magic-wormhole-rs
        pkgs.adwaita-icon-theme # cursor theme
        pkgs.nautilus
        pkgs.alacritty
        pkgs.brightnessctl
        cliphist-picker
        pkgs.dev.johnrinehart.cliphist-master
        pkgs.dev.johnrinehart.fuzzel_1_15_0
        pkgs.grim
        pkgs.awww
        pkgs.satty
        pkgs.slurp
        pkgs.waybar
        pkgs.wl-clip-persist
        pkgs.wl-clipboard
        pkgs.xwayland-satellite
        # (builtins.getFlake "github:niri-wm/niri?rev=${niriRev}").packages.${pkgs.stdenv.hostPlatform.system}.niri
      ]
      ++ [
        myMako
      ];

    environment.etc."niri/config.kdl".source =
      let
        fuzzelDmenu = pkgs.dev.johnrinehart.fuzzel-dmenu.override {
          fuzzel = pkgs.dev.johnrinehart.fuzzel_1_15_0;
          niri = config.programs.niri.package;
        };
        niriBase = pkgs.replaceVarsWith {
          src = ./niri.kdl;
          replacements = {
            terminal_emulator = lib.getExe terminalEmulator;
            terminal_emulator_name = lib.getName terminalEmulator;
            fuzzel_dmenu = lib.getExe fuzzelDmenu;
            focus_or_spawn = lib.getExe focus-or-spawn;
            clipboard_watch = lib.getExe clipboard-watch;
            cliphist_picker = lib.getExe cliphist-picker;
            input_toggle_notify = lib.getExe input-toggle-notify;
            keyboard_brightness_notify = lib.getExe keyboard-brightness-notify;
            lock_command = "${lib.getExe' pkgs.systemd "loginctl"} lock-session";
            monitor_power_notify = lib.getExe monitor-power-notify;
            suspend = "${lib.getExe' pkgs.systemd "systemctl"} ${config.dev.johnrinehart.system.suspendVerb}";
            wl-kbptr = lib.getExe pkgs.wl-kbptr;
            brightness_notify = lib.getExe brightness-notify;
            display_layout_editor = lib.getExe display-layout;
            niri_cycle_display_mode = lib.getExe niri-cycle-display-mode;
            niri_screenshot = lib.getExe niri-screenshot;
            playerctl = lib.getExe pkgs.playerctl;
            volume_notify = lib.getExe volume-notify;
            wormhole_send = lib.getExe wormhole-send;
            xcursor_theme = xcursorTheme;
            extra_niri_config = cfg.niri.extraConfig;
            extra_niri_keybindings = lib.concatMapStrings (bindings: "\n${indentKdlLines "    " bindings}") (
              lib.optional cfg.face.enable faceScanKeybinding
              ++ lib.optional (cfg.niri.extraKeybindings != "") cfg.niri.extraKeybindings
            );
          };
        };
      in
      (pkgs.substitute {
        src = niriBase;
        substitutions = [
          "--replace-fail"
          "xcursor-size 24"
          "xcursor-size ${toString xcursorSize}"
        ];
      }).overrideAttrs
        (_: {
          checkPhase = null;
        });
    environment.etc."xdg/waybar".source =
      let
        defaultInterfaceLine = ''// "interface": "wlp2*", // (Optional) To force the use of this interface'';
        configuredInterfaceLine =
          if cfg.waybar.connectivityInterfacePattern == null then
            defaultInterfaceLine
          else
            ''"interface": ${builtins.toJSON cfg.waybar.connectivityInterfacePattern},'';
        waybarConfig = pkgs.substitute {
          src = ./waybar/config.jsonc;
          substitutions = [
            "--replace-fail"
            defaultInterfaceLine
            configuredInterfaceLine
            # Waybar's user unit runs with a minimal PATH, so bare names from
            # the system profile do not resolve.
            "--subst-var-by"
            "niri_cycle_display_mode"
            (lib.getExe niri-cycle-display-mode)
          ];
        };
      in
      pkgs.runCommand "johnos-waybar-config" { } ''
        mkdir -p "$out"
        cp -R ${./waybar}/. "$out/"
        install -m 0644 ${waybarConfig} "$out/config.jsonc"
      '';
    environment.etc."mako/config".source =
      (pkgs.replaceVars ./mako.conf {
        adwaita_icons = "${pkgs.adwaita-icon-theme}/share/icons/Adwaita";
        gnome_icons = "${pkgs.gnome-icon-theme}/share/icons/gnome";
      }).overrideAttrs
        (_: {
          checkPhase = null;
        });

    # Custom PAM config - applied to authentication services. See
    # authPamConfig for the order of the password and biometric factors.
    security.pam.services =
      lib.genAttrs
        [
          "greetd"
          "hyprlock"
          "login"
          "polkit-1"
          "sudo"
          "swaylock"
        ]
        (_: {
          enableGnomeKeyring = true;
          text = authPamConfig;
        })
      // {
        # greetd starts its default greeter through this PAM service without
        # running authentication. Define the account/session phases explicitly;
        # otherwise Linux-PAM falls back to the deny-all `other` service and
        # tuigreet cannot start after reboot.
        greetd-greeter.text = ''
          auth required pam_permit.so
          account required pam_permit.so
          password required pam_deny.so
          session required pam_env.so conffile=/etc/pam/environment readenv=0
          session required pam_unix.so
          session optional ${pkgs.systemd}/lib/security/pam_systemd.so
        '';
        # `passwd` also re-encrypts the login keyring with the new password.
        # Without it, the next login cannot unlock the keyring. pam_unix is
        # `sufficient` by default, which ends the stack before the keyring.
        passwd = {
          enableGnomeKeyring = true;
          rules.password.unix.control = lib.mkForce "required";
        };
      }
      // lib.optionalAttrs cfg.face.enable {
        su.text = ownSessionPamConfig {
          authFirst = ''
            auth sufficient pam_rootok.so
            auth required pam_faillock.so
          '';
          session = "session optional pam_xauth.so systemuser=99 xauthpath=${pkgs.xauth}/bin/xauth";
        };
        vlock.text = ownSessionPamConfig { session = ""; };
      };

    services.pam-biometrics = lib.mkIf cfg.face.enable {
      enable = true;
      camera = {
        inherit (cfg.face) device inputFormat;
      };
      greeterUser = config.services.greetd.settings.default_session.user;
      # The default prompts name the Enter trigger and the reader. After the
      # password, graphical clients have no terminal for Enter, so their wait
      # names the key binding instead (Super+Alt+F; tuigreet's Alt+F).
      policy =
        let
          seconds = toString cfg.fingerprint.timeoutSeconds;
          keyWait =
            key:
            (if cfg.fingerprint.enable then "Touch the fingerprint reader or press " else "Press ")
            + "${key} to scan your face (${seconds} s).";
        in
        {
          defaults = {
            factors = lib.optional cfg.fingerprint.enable "fingerprint" ++ [ "face" ];
            timeout_seconds = cfg.fingerprint.timeoutSeconds;
          };
          services = {
            hyprlock.wait_message = keyWait "Super+Alt+F";
            swaylock.wait_message = keyWait "Super+Alt+F";
            greetd.wait_message = keyWait "Alt+F";
          };
        };
    };

    # hyprlock runs SIGUSR2 force updates inside the signal handler. When the
    # signal interrupts the main thread inside getpwuid(), malloc(), or a timer
    # mutex, the handler's label update waits on that lock forever and the
    # lock screen hangs, even after PAM succeeds. face-scan-key sends SIGUSR2
    # as a scan ends, right when PAM finishes and hyprlock redraws.
    # hyprwm/hyprlock#1062, an open pull request, defers the update to the main
    # loop through a self-pipe. It does not apply to 0.9.5, so build main. The
    # overlay covers programs.hyprlock and home-manager's pkgs.hyprlock alike.
    # Drop it once a release includes the fix.
    nixpkgs.overlays = [
      (_final: prev: {
        hyprlock = prev.hyprlock.overrideAttrs (old: {
          version = "0.9.6-unstable-2026-10-30";
          src = prev.fetchFromGitHub {
            owner = "hyprwm";
            repo = "hyprlock";
            rev = "9de871992f64e517eb8a56f363c5acd13690308f";
            hash = "sha256-PVvBqN7etoTvEK9CTNLZ3Wwgi6Pcy4YMUX8KHSUb8EE=";
          };
          # nixpkgs builds the changelog URL from src.tag, which a rev leaves null.
          meta = old.meta // {
            changelog = "https://github.com/hyprwm/hyprlock/commits/9de871992f64e517eb8a56f363c5acd13690308f";
          };
          patches = (old.patches or [ ]) ++ [
            # https://github.com/hyprwm/hyprlock/pull/1062
            (prev.fetchpatch2 {
              name = "core-fix-async-signal-safety-of-the-sigusr2-handler.patch";
              url = "https://github.com/hyprwm/hyprlock/commit/afdf00b9b857f14e8f7f1d15039bde9ba05b7043.patch?full_index=1";
              hash = "sha256-7m62eG3WeWj0+0cFXrzJa4Dz5RegHBOEcFtRQ3EYi0M=";
            })
          ];
        });
      })
    ];

    services.hypridle.enable = true;
    programs.hyprlock.enable = true;
  };
}
