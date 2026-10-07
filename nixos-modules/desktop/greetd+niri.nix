{
  config,
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

  niriPatches = [
    ./0000-version-report-downstream-patches.patch
    ./0001-overview-allow-targeting-active-output.patch
    ./0002-screencast-accept-remote-desktop-sessions.patch
  ];
  niriDependencyPatches = [
    ./0003-niri-pin-smithay-drm-extras-crtc-recovery.patch
  ];
  allNiriPatches = niriPatches ++ niriDependencyPatches;
  niriPatchVersionSuffix = lib.concatMapStrings (
    patch: "\n+ ${builtins.baseNameOf (toString patch)}"
  ) allNiriPatches;
  niriWithScopedOverview = pkgs.niri.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ allNiriPatches;

    # A connected connector can initially have no free compatible CRTC. If a
    # later scan releases one, Smithay can map the connector without a state or
    # mode change, so Niri receives no event and never records the new mapping.
    # Pin https://github.com/Smithay/smithay/pull/2125 until Niri consumes it.
    # The pinned commit also includes the DP-MST stale-reservation fix from
    # https://github.com/Smithay/smithay/pull/2076.
    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      name = "${old.pname}-${old.version}";
      inherit (old) src;
      patches = (old.cargoPatches or [ ]) ++ niriDependencyPatches;
      hash = "sha256-PB5P3h8ZA9kPTFEbQMpA/ms/k+kejvTqTgqSoXcgK/w=";
    };
    env = (old.env or { }) // {
      NIRI_BUILD_PATCHES = niriPatchVersionSuffix;
    };
  });

  niri-screenshot = pkgs.dev.johnrinehart.niri-screenshot.override {
    niri = config.programs.niri.package;
    inherit wormhole-send;
  };

  inherit (pkgs.dev.johnrinehart)
    brightness-notify
    input-toggle-notify
    keyboard-brightness-notify
    monitor-power-notify
    volume-notify
    ;

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

  # Shared PAM configuration for password authentication with an optional
  # fingerprint factor.
  fprintPamConfig = ''
    # Account management
    account required pam_unix.so

    # Authentication management
    ${lib.optionalString cfg.fingerprint.enable ''
      # Fingerprint: success→continue, timeout/unavailable→continue, wrong→reject immediately
      auth [success=ok ignore=ignore authinfo_unavail=ignore default=die] ${pkgs.fprintd}/lib/security/pam_fprintd.so timeout=${toString cfg.fingerprint.timeoutSeconds}
    ''}
    # Password is always required (do NOT use try_first_pass - we need fresh password for keyring)
    auth required pam_unix.so nullok
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
          description = "Seconds to wait for fingerprint authentication before timing out.";
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
  };

  config = lib.mkIf cfg.enable {
    environment.sessionVariables = {
      NIXOS_OZONE_WL = "1";
      XCURSOR_THEME = xcursorTheme;
      XCURSOR_SIZE = toString xcursorSize;
    };

    programs.niri.enable = true;

    # Use Nautilus through the GNOME portal for file chooser grid view.
    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-gnome ];
      config.niri."org.freedesktop.impl.portal.FileChooser" = "gnome";
    };

    # nixpkgs' niri with the downstream patches above and the patched
    # smithay-drm-extras vendor set.
    programs.niri.package = niriWithScopedOverview;

    users.users.${primaryUser}.extraGroups = [ "seat" ];

    services.greetd.enable = true;
    services.fprintd.enable = lib.mkIf cfg.fingerprint.enable true;
    # Raise the fd soft limit so children (waybar, etc.) don't hit the
    # default 1024 and fail with "Too many open files" on boot.
    systemd.services.greetd.serviceConfig.LimitNOFILE = "524288";
    services.greetd.settings.default_session = {
      command = "${lib.getExe' config.programs.niri.package "niri-session"}";
      user = primaryUser;
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
            clipboard_watch = lib.getExe clipboard-watch;
            cliphist_picker = lib.getExe cliphist-picker;
            input_toggle_notify = lib.getExe input-toggle-notify;
            keyboard_brightness_notify = lib.getExe keyboard-brightness-notify;
            lock_command = "${lib.getExe' pkgs.systemd "loginctl"} lock-session";
            monitor_power_notify = lib.getExe monitor-power-notify;
            suspend = "${lib.getExe' pkgs.systemd "systemctl"} suspend-then-hibernate";
            wl-kbptr = lib.getExe pkgs.wl-kbptr;
            brightness_notify = lib.getExe brightness-notify;
            display_layout_editor = lib.getExe display-layout;
            niri_cycle_display_mode = lib.getExe niri-cycle-display-mode;
            niri_screenshot = lib.getExe niri-screenshot;
            volume_notify = lib.getExe volume-notify;
            wormhole_send = lib.getExe wormhole-send;
            xcursor_theme = xcursorTheme;
            extra_niri_config = cfg.niri.extraConfig;
            extra_niri_keybindings = lib.optionalString (
              cfg.niri.extraKeybindings != ""
            ) "\n${indentKdlLines "    " cfg.niri.extraKeybindings}";
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

    # Custom PAM config: fingerprint as first factor (rejects bad
    # fingerprints), then mandatory password - applied to authentication
    # services
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
          text = fprintPamConfig;
        });

    services.hypridle.enable = true;
    programs.hyprlock.enable = true;
  };
}
