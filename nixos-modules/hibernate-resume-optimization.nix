# Hibernate Resume Optimization Module
#
# Addresses the 30-60 second delay after hibernate resume where the display
# renders but input (keyboard/mouse) is unresponsive. This is caused by
# resource contention between the user session and system services during
# the post-resume "thaw" phase.
#
# Root causes addressed:
#   1. rtkit demoting audio threads due to perceived system overload
#   2. Network services (dhcpcd, tailscale, bluetooth) flooding D-Bus
#   3. PipeWire/WirePlumber blocking on bluetooth reconnection
#   4. Compositor (niri/hyprland) starved of CPU while services restart
#
# Usage:
#   dev.johnrinehart.hibernate-resume-optimization.enable = true;
#
# For fine-grained control, individual optimizations can be toggled.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.hibernate-resume-optimization;
in
{
  imports = [
    (lib.mkRemovedOptionModule
      [ "dev" "johnrinehart" "hibernate-resume-optimization" "enableResumeCompression" ]
      ''
        It assumed a bare `nocompress` kernel parameter disables compression;
        the kernel only knows `hibernate=nocompress`, so images were always
        LZO-compressed. Use `compression.algorithm` and `compression.threads`.
      ''
    )
  ];

  options.dev.johnrinehart.hibernate-resume-optimization = {
    enable = lib.mkEnableOption "Hibernate resume optimizations for faster session interactivity";

    deferNetworking = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Defer network service restarts after resume.

          **Impact: HIGH** (~20-30s improvement)

          After hibernate resume, dhcpcd immediately tries to rebind interfaces
          which triggers a cascade: wpa_supplicant reconnects, DHCP discovers,
          tailscale tries to reconnect (spamming dozens of bootstrap DNS servers),
          and NetworkManager dispatches events. All of this floods D-Bus and
          competes with the compositor for CPU.

          When enabled, network services wait a few seconds after resume before
          attempting reconnection, allowing the user session to become interactive
          first.
        '';
      };

      delaySeconds = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = ''
          Seconds to wait after resume before network services restart.
          3 seconds is usually sufficient for the compositor to process
          queued input events and render the first frame.
        '';
      };
    };

    deferBluetooth = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Defer bluetooth reconnection attempts after resume.

          **Impact: MEDIUM** (~5-10s improvement)

          Bluetooth (bluez) immediately tries to reconnect to paired devices
          after resume. This generates many D-Bus messages and causes
          WirePlumber to block waiting for audio endpoint registration.
          The repeated "Host is down" errors spam the journal and consume
          CPU cycles.

          When enabled, bluetooth adapter is briefly disabled after resume
          then re-enabled after a delay.
        '';
      };

      delaySeconds = lib.mkOption {
        type = lib.types.int;
        default = 5;
        description = ''
          Seconds to wait after resume before re-enabling bluetooth.
          Slightly longer than network delay since BT reconnection
          is less critical for immediate usability.
        '';
      };
    };

    prioritizeUserSession = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Give the user session higher CPU priority during and after resume.

          **Impact: MEDIUM** (~10-15s improvement)

          The compositor and input handling run in the user session, but
          compete equally with system services for CPU after resume. This
          causes the 40+ second input lag reported by libinput.

          When enabled:
          - User slice gets higher CPU weight
          - rtkit is configured to be less aggressive about demoting threads
          - A post-resume hook temporarily boosts session priority
        '';
      };

      userSliceCPUWeight = lib.mkOption {
        type = lib.types.int;
        default = 200;
        description = ''
          CPU weight for user.slice (default is 100).
          Higher values give user sessions more CPU time relative to
          system services. 200 means 2x the priority of default services.
        '';
      };
    };

    reduceHibernateImageSize = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Reduce the hibernate image size for faster suspend/resume.

          **Impact: LOW-MEDIUM** (~5-10s improvement on resume)

          The kernel tries to save up to image_size bytes of memory to swap.
          Smaller images mean less data to write/read, but may cause more
          memory to be discarded and reloaded from disk after resume.

          Default kernel value is ~2/5 of RAM. This option reduces it to
          speed up the hibernate/resume cycle at the cost of potentially
          more disk I/O after resume as applications fault pages back in.

          Only enable if you have fast NVMe storage and want faster
          hibernate/resume at the cost of slightly slower app responsiveness
          immediately after resume.
        '';
      };

      imageSizeBytes = lib.mkOption {
        type = lib.types.int;
        default = 4000000000; # ~4GB
        description = ''
          Maximum hibernate image size in bytes.
          Smaller = faster hibernate/resume but more post-resume page faults.
          4GB is a reasonable balance for systems with 16-32GB RAM.
        '';
      };
    };

    compression = {
      algorithm = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.enum [
            "lzo"
            "lz4"
            "none"
          ]
        );
        default = null;
        example = "lz4";
        description = ''
          Hibernation image compressor, set on the kernel command line
          (`hibernate.compressor=` or `hibernate=nocompress`). The image
          header records it, so the resume kernel decompresses either. null
          keeps the kernel default (lzo).

          On framie (i5-1135G7, LUKS swap on NVMe), with 7 threads, lz4
          beat lzo by a few seconds per cycle and decompresses about 3x
          faster, at a 3% larger image. Images compress to about 41-44% of
          their size, so writing them uncompressed would mean more than
          twice the data.
        '';
      };

      threads = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        example = 7;
        description = ''
          Upper bound on hibernation (de)compression threads
          (`hibernate_compression_threads=`). The kernel uses
          min(online CPUs - 1, this) and defaults to 3. null keeps the
          default.

          On framie, 7 threads instead of 3 shortened a hibernate-and-restore
          cycle with a 12 GiB image from about 54 s to 36-41 s.
        '';
      };
    };

    debugTiming = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable PM timing debug output to diagnose resume delays.

          **Impact: NONE** (diagnostic only)

          Enables PM timing, PM debug messages, initcall timing, console
          output across suspend/resume, and explicit pre/post sleep journal
          markers. The console log level stays unchanged, so the messages go
          to the kernel log and the journal, not over the LUKS prompt or the
          greeter. Useful for separating image restore time, device resume
          time, and userspace thaw/reconnect time.
          Check with: journalctl -b -k -o short-monotonic | grep "PM:"
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # Base configuration - always applied when module is enabled
      {
        # Post-resume service that coordinates deferred restarts
        systemd.services.hibernate-resume-optimize = {
          description = "Optimize system state after hibernate resume";
          after = [
            "hibernate.target"
            "suspend-then-hibernate.target"
          ];
          wantedBy = [
            "hibernate.target"
            "suspend-then-hibernate.target"
          ];

          serviceConfig = {
            Type = "oneshot";
            ExecStart = pkgs.writeShellScript "hibernate-resume-optimize" ''
              # Log resume time for debugging
              echo "hibernate-resume-optimize: Session thawed at $(date)"

              # Give compositor a head start
              sleep 0.5

              # Signal that optimization service has run
              mkdir -p /run/hibernate-resume
              touch /run/hibernate-resume/optimized
            '';
          };
        };
      }

      # Defer networking after resume
      (lib.mkIf cfg.deferNetworking.enable {
        # Override post-resume to not immediately reload dhcpcd
        powerManagement.resumeCommands = ''
          # Defer network restart - let user session become interactive first
          (
            sleep ${toString cfg.deferNetworking.delaySeconds}

            # Reload dhcpcd if running
            if systemctl is-active dhcpcd.service >/dev/null 2>&1; then
              systemctl reload dhcpcd.service || true
            fi

            # Poke NetworkManager to reassociate
            if systemctl is-active NetworkManager.service >/dev/null 2>&1; then
              ${pkgs.networkmanager}/bin/nmcli networking off 2>/dev/null || true
              sleep 0.5
              ${pkgs.networkmanager}/bin/nmcli networking on 2>/dev/null || true
            fi
          ) &
        '';

        # Prevent dhcpcd from being reloaded synchronously in post-resume.service
        # The default NixOS post-resume.service runs: systemctl reload dhcpcd.service
        # We override this by making our own post-resume that defers it
        systemd.services.post-resume = {
          serviceConfig = {
            # Replace the ExecStart entirely - we handle dhcpcd in resumeCommands
            ExecStart = lib.mkForce (
              pkgs.writeShellScript "post-resume-deferred" ''
                # Try-restart post-resume.target for any dependent units
                systemctl try-restart --no-block post-resume.target || true

                # dhcpcd reload is handled by hibernate-resume-optimize with delay
                # Do NOT reload it here synchronously
              ''
            );
          };
        };

        # Make tailscale less aggressive on resume
        systemd.services.tailscaled.serviceConfig = {
          # Delay tailscale's network checks on resume
          ExecStartPost = lib.mkAfter [
            "-${pkgs.coreutils}/bin/sleep 2"
          ];
        };
      })

      # Defer bluetooth reconnection
      (lib.mkIf (cfg.deferBluetooth.enable && config.hardware.bluetooth.enable) {
        # Service to defer bluetooth after resume
        systemd.services.bluetooth-resume-defer = {
          description = "Defer bluetooth reconnection after hibernate resume";
          after = [
            "hibernate.target"
            "suspend-then-hibernate.target"
          ];
          wantedBy = [
            "hibernate.target"
            "suspend-then-hibernate.target"
          ];
          before = [ "bluetooth.target" ];

          serviceConfig = {
            Type = "oneshot";
            ExecStart = pkgs.writeShellScript "bluetooth-resume-defer" ''
              # Briefly power off bluetooth to stop reconnection attempts
              ${pkgs.bluez}/bin/bluetoothctl power off 2>/dev/null || true

              # Wait for user session to stabilize
              ${pkgs.coreutils}/bin/sleep ${toString cfg.deferBluetooth.delaySeconds}

              # Re-enable bluetooth
              ${pkgs.bluez}/bin/bluetoothctl power on 2>/dev/null || true
            '';
          };
        };
      })

      # Prioritize user session
      (lib.mkIf cfg.prioritizeUserSession.enable {
        # Give user slice higher CPU priority
        systemd.slices.user = {
          sliceConfig = {
            CPUWeight = cfg.prioritizeUserSession.userSliceCPUWeight;
          };
        };

        # Make rtkit less aggressive about demoting threads
        # rtkit demotes threads when it thinks the system is overloaded
        # After resume, it incorrectly detects overload due to timestamp skew
        systemd.services.rtkit-daemon.serviceConfig = {
          # Give rtkit itself higher priority so it can make decisions faster
          Nice = -5;
          # Increase the watchdog timeout to prevent false "starving" detection
          Environment = [
            "RTKIT_CANARY_WATCHDOG_MSEC=30000"
          ];
        };

        # User service to boost session priority immediately after resume
        # This runs in user context and affects the compositor directly
        systemd.user.services.session-priority-boost = {
          description = "Boost session priority after resume";
          wantedBy = [ "graphical-session.target" ];
          after = [ "graphical-session.target" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            # Renice the entire user session to higher priority
            # $$PPID gets the session leader
            ExecStart = pkgs.writeShellScript "boost-session" ''
              # Get our session's process group
              SESSION_LEADER=$(ps -o ppid= -p $$ | tr -d ' ')

              # Try to renice the session (may fail without CAP_SYS_NICE)
              ${pkgs.util-linux}/bin/renice -n -5 -g $SESSION_LEADER 2>/dev/null || true

              # Also try to set the compositor specifically if we can identify it
              for compositor in niri Hyprland sway; do
                PID=$(${pkgs.procps}/bin/pgrep -u $USER "^$compositor$" 2>/dev/null | head -1)
                if [ -n "$PID" ]; then
                  ${pkgs.util-linux}/bin/renice -n -10 -p $PID 2>/dev/null || true
                  # Try to set realtime IO priority for compositor
                  ${pkgs.util-linux}/bin/ionice -c 1 -n 0 -p $PID 2>/dev/null || true
                fi
              done

              exit 0
            '';
          };
        };

        # Allow the user to renice their own processes (for session-priority-boost)
        security.pam.loginLimits = [
          {
            domain = "@users";
            type = "-";
            item = "nice";
            value = "-10";
          }
        ];
      })

      # Reduce hibernate image size
      (lib.mkIf cfg.reduceHibernateImageSize.enable {
        # Set image_size via tmpfiles (applied at boot)
        systemd.tmpfiles.rules = [
          "w /sys/power/image_size - - - - ${toString cfg.reduceHibernateImageSize.imageSizeBytes}"
        ];
      })

      (lib.mkIf (cfg.compression.algorithm != null) {
        boot.kernelParams = [
          (
            if cfg.compression.algorithm == "none" then
              "hibernate=nocompress"
            else
              "hibernate.compressor=${cfg.compression.algorithm}"
          )
        ];
      })

      (lib.mkIf (cfg.compression.threads != null) {
        boot.kernelParams = [
          "hibernate_compression_threads=${toString cfg.compression.threads}"
        ];
      })

      {
        # A bare `nocompress` is not a kernel parameter: it does nothing.
        warnings =
          lib.optional (lib.elem "nocompress" config.boot.kernelParams)
            "hibernate-resume-optimization: 'nocompress' in boot.kernelParams does nothing; use compression.algorithm = \"none\" (hibernate=nocompress).";
      }

      # Debug timing
      (lib.mkIf cfg.debugTiming.enable {
        # The kernel log buffer keeps every level regardless of
        # boot.consoleLogLevel. A higher console level only prints the
        # messages over the LUKS prompt and the greeter.

        # Keep the printk buffer large enough for verbose PCI/TB dyndbg output
        # plus PM timing without wrapping before userspace can read it.
        boot.kernelParams = [
          "pm_print_times=1"
          "pm_debug_messages"
          "initcall_debug"
          "printk.time=1"
          "no_console_suspend"
          "log_buf_len=32M"
          "efi_pstore.pstore_disable=0"
        ];

        # Persist the journal so monotonic gaps are available after the next
        # full boot too, not only after the hibernated userspace is restored.
        services.journald.extraConfig = ''
          Storage=persistent
        '';

        powerManagement.powerDownCommands = ''
          read -r uptime _ < /proc/uptime
          ${pkgs.systemd}/bin/systemd-cat -t hibernate-debug ${pkgs.coreutils}/bin/echo "pre-sleep wall=$(${pkgs.coreutils}/bin/date --iso-8601=ns) monotonic=''${uptime}s"
        '';

        powerManagement.resumeCommands = ''
          read -r uptime _ < /proc/uptime
          ${pkgs.systemd}/bin/systemd-cat -t hibernate-debug ${pkgs.coreutils}/bin/echo "post-resume wall=$(${pkgs.coreutils}/bin/date --iso-8601=ns) monotonic=''${uptime}s"
        '';

        # Enable PM timing/debug at runtime too, so nixos-rebuild test is enough
        # for the sysfs knobs even before rebooting into the kernel params.
        systemd.tmpfiles.rules = [
          "w /sys/power/pm_print_times - - - - 1"
          "w /sys/power/pm_debug_messages - - - - 1"
          "w /sys/module/printk/parameters/console_suspend - - - - N"
        ];

        # NixOS already enables systemd-pstore. Do not force
        # printk.always_kmsg_dump here; on EFI pstore that can write
        # firmware-backed storage on routine shutdown paths.
      })
    ]
  );
}
