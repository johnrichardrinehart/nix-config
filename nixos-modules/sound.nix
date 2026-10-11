{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.dev.johnrinehart.sound;
  highpassNode = {
    type = "builtin";
    name = "highpass";
    label = "bq_highpass";
    control = {
      "Freq" = cfg.rnnoise.highpass.frequency;
      "Q" = cfg.rnnoise.highpass.q;
    };
  };
  rnnoiseNode = {
    type = "ladspa";
    name = "rnnoise";
    plugin = "librnnoise_ladspa";
    label = "noise_suppressor_mono";
    control = {
      "VAD Threshold (%)" = cfg.rnnoise.vadThreshold;
      "VAD Grace Period (ms)" = cfg.rnnoise.vadGracePeriod;
      "Retroactive VAD Grace (ms)" = cfg.rnnoise.retroactiveVadGrace;
    };
  };
  deepfilterNode = {
    type = "ladspa";
    name = "deepfilter";
    plugin = "libdeep_filter_ladspa";
    label = "deep_filter_mono";
    control = {
      "Attenuation Limit (dB)" = cfg.rnnoise.deepfilter.attenuationLimit;
      "Min processing threshold (dB)" = cfg.rnnoise.deepfilter.minProcessingThreshold;
      "Max ERB processing threshold (dB)" = cfg.rnnoise.deepfilter.maxErbProcessingThreshold;
      "Max DF processing threshold (dB)" = cfg.rnnoise.deepfilter.maxDfProcessingThreshold;
      "Min Processing Buffer (frames)" = cfg.rnnoise.deepfilter.minProcessingBuffer;
      "Post Filter Beta" = cfg.rnnoise.deepfilter.postFilterBeta;
    };
  };
  deepfilterBeforeRnnoise = cfg.rnnoise.deepfilter.position == "beforeRnnoise";
  deepfilterAfterRnnoise = cfg.rnnoise.deepfilter.position == "afterRnnoise";
  rnnoiseFinalOutput =
    if cfg.rnnoise.deepfilter.enable && deepfilterAfterRnnoise then
      "deepfilter:Audio Out"
    else
      "rnnoise:Output";
  dualMonoFanoutNodes = [
    {
      type = "builtin";
      name = "stereo-left";
      label = "copy";
    }
    {
      type = "builtin";
      name = "stereo-right";
      label = "copy";
    }
  ];
  rnnoiseNodes =
    lib.optionals cfg.rnnoise.highpass.enable [ highpassNode ]
    ++ lib.optionals (cfg.rnnoise.deepfilter.enable && deepfilterBeforeRnnoise) [ deepfilterNode ]
    ++ [ rnnoiseNode ]
    ++ lib.optionals (cfg.rnnoise.deepfilter.enable && deepfilterAfterRnnoise) [ deepfilterNode ]
    ++ lib.optionals cfg.rnnoise.dualMonoOutput.enable dualMonoFanoutNodes;
  rnnoiseLinks =
    lib.optionals
      (cfg.rnnoise.highpass.enable && cfg.rnnoise.deepfilter.enable && deepfilterBeforeRnnoise)
      [
        {
          output = "highpass:Out";
          input = "deepfilter:Audio In";
        }
      ]
    ++
      lib.optionals
        (cfg.rnnoise.highpass.enable && (!cfg.rnnoise.deepfilter.enable || deepfilterAfterRnnoise))
        [
          {
            output = "highpass:Out";
            input = "rnnoise:Input";
          }
        ]
    ++ lib.optionals (cfg.rnnoise.deepfilter.enable && deepfilterBeforeRnnoise) [
      {
        output = "deepfilter:Audio Out";
        input = "rnnoise:Input";
      }
    ]
    ++ lib.optionals (cfg.rnnoise.deepfilter.enable && deepfilterAfterRnnoise) [
      {
        output = "rnnoise:Output";
        input = "deepfilter:Audio In";
      }
    ]
    ++ lib.optionals cfg.rnnoise.dualMonoOutput.enable [
      {
        output = rnnoiseFinalOutput;
        input = "stereo-left:In";
      }
      {
        output = rnnoiseFinalOutput;
        input = "stereo-right:In";
      }
    ];
in
{
  options.dev.johnrinehart.sound = {
    enable = lib.mkEnableOption "John's sound config";

    rnnoise = {
      inputRules = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
        description = ''
          WirePlumber monitor.alsa.rules entries used to rank or otherwise
          configure physical capture sources that can back rnnoise_source.

          The sound module intentionally leaves these host-specific. For
          example, a laptop configuration can prefer an external USB microphone
          over the built-in microphone by raising priority.session on matching
          Audio/Source nodes.
        '';
      };
      followDefaultInput = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Enable WirePlumber default-target following so the RNNoise capture
          stream moves when the preferred physical capture source changes, such
          as when a USB microphone is plugged or unplugged after startup.
        '';
      };
      vadThreshold = lib.mkOption {
        type = lib.types.float;
        default = 50.0;
        description = "RNNoise VAD threshold percentage.";
      };
      vadGracePeriod = lib.mkOption {
        type = lib.types.float;
        default = 500.0;
        description = "RNNoise VAD grace period in milliseconds.";
      };
      retroactiveVadGrace = lib.mkOption {
        type = lib.types.float;
        default = 100.0;
        description = "RNNoise retroactive VAD grace period in milliseconds.";
      };
      highpass = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable a builtin PipeWire high-pass filter before RNNoise.";
        };
        frequency = lib.mkOption {
          type = lib.types.float;
          default = 120.0;
          description = "High-pass cutoff frequency in Hz when rnnoise.highpass.enable is true.";
        };
        q = lib.mkOption {
          type = lib.types.float;
          default = 0.707;
          description = "High-pass biquad Q value when rnnoise.highpass.enable is true.";
        };
      };
      dualMonoOutput = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Fan the mono RNNoise output out to a two-channel dual-mono virtual
            source. This is useful for applications that handle mono capture
            poorly but adds a small amount of extra PipeWire graph work.
          '';
        };
      };
      deepfilter = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Enable DeepFilterNet in the virtual microphone filter chain.";
        };
        position = lib.mkOption {
          type = lib.types.enum [
            "beforeRnnoise"
            "afterRnnoise"
          ];
          default = "beforeRnnoise";
          description = "Place DeepFilterNet before or after RNNoise. The high-pass filter, when enabled, always remains first.";
        };
        attenuationLimit = lib.mkOption {
          type = lib.types.float;
          default = 100.0;
          description = "DeepFilterNet attenuation limit in dB.";
        };
        minProcessingThreshold = lib.mkOption {
          type = lib.types.float;
          default = -15.0;
          description = "DeepFilterNet minimum processing threshold in dB.";
        };
        maxErbProcessingThreshold = lib.mkOption {
          type = lib.types.float;
          default = 35.0;
          description = "DeepFilterNet maximum ERB processing threshold in dB.";
        };
        maxDfProcessingThreshold = lib.mkOption {
          type = lib.types.float;
          default = 35.0;
          description = "DeepFilterNet maximum deep-filter processing threshold in dB.";
        };
        minProcessingBuffer = lib.mkOption {
          type = lib.types.float;
          default = 0.0;
          description = "DeepFilterNet minimum processing buffer in frames.";
        };
        postFilterBeta = lib.mkOption {
          type = lib.types.float;
          default = 0.0;
          description = "DeepFilterNet post-filter beta.";
        };
      };
    };

    softwareMicMonitor.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable a PipeWire software loopback that plays the processed
        rnnoise_source through the default audio output. This is independent
        of hardware direct-monitoring controls provided by devices such as the
        Samson Q9U.
      '';
    };

    debug = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable PipeWire debug logging via PIPEWIRE_DEBUG environment variable.";
      };
      level = lib.mkOption {
        type = lib.types.ints.between 0 5;
        default = 4;
        description = ''
          PipeWire log level: 0=none, 1=errors, 2=warnings, 3=info, 4=debug, 5=trace.
          Level 5 (trace) logs from realtime threads and will impact audio performance.
          Level 4 (debug) is the recommended maximum for ongoing use.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # PAM limits for the @audio group — foundation for realtime audio
    security.pam.loginLimits = [
      {
        domain = "@audio";
        type = "-";
        item = "memlock";
        value = "unlimited";
      }
      {
        domain = "@audio";
        type = "-";
        item = "rtprio";
        value = "95";
      }
      {
        domain = "@audio";
        type = "-";
        item = "nice";
        value = "-15";
      }
    ];

    # Persist hardware mixer controls, including USB microphone controls, and
    # restore them from udev when devices are hotplugged.
    #
    # Nixpkgs notes that ALSA persistence is generally unnecessary when using
    # an external sound server. That advice applies to normal desktop routing,
    # stream volumes, and default devices, which WirePlumber owns here. We still
    # enable only the persistence hook because USB devices can expose hardware
    # mixer controls outside WirePlumber's durable policy model. The Samson Q9U
    # is one such device: its Mic Gain, HP Volume, and Direct monitoring controls
    # are ALSA device controls that can reset across unplug/replug unless
    # alsactl restores the card state on hotplug.
    hardware.alsa.enablePersistence = true;

    # PipeWire's PulseAudio compatibility daemon intentionally does not put the
    # PulseAudio client tools on PATH. Keep pactl/pacat available whenever this
    # module enables services.pipewire.pulse.
    environment.systemPackages = lib.mkIf config.services.pipewire.pulse.enable [ pkgs.pulseaudio ];

    services.pipewire = {
      enable = true;

      alsa.enable = true;
      alsa.support32Bit = false;
      pulse.enable = true;
      wireplumber = {
        enable = true;
        extraConfig = lib.mkMerge [
          (lib.mkIf (cfg.rnnoise.inputRules != [ ]) {
            "51-rnnoise-capture-source-policy" = {
              "monitor.alsa.rules" = cfg.rnnoise.inputRules;
            };
          })
          (lib.mkIf cfg.rnnoise.followDefaultInput {
            "52-rnnoise-follow-default-input" = {
              "wireplumber.settings" = {
                "linking.follow-default-target" = true;
              };
            };
          })
        ];
      };
      extraLadspaPackages = [
        pkgs.rnnoise-plugin.ladspa
      ]
      ++ lib.optionals cfg.rnnoise.deepfilter.enable [ pkgs.deepfilternet ];

      jack.enable = false;

      extraConfig.pipewire = {
        "10-low-latency" = {
          "context.properties" = {
            # 256/48000 is about 5.3 ms per processing block. This keeps the
            # processed microphone monitor usable while leaving room to back off
            # to 512 if DeepFilterNet or USB audio starts underrunning.
            "default.clock.quantum" = 256;
            "default.clock.min-quantum" = 128;
            "default.clock.max-quantum" = 512;
          };
        };

        # RNNoise noise suppression — replaces NoiseTorch.
        # Expose one stable virtual source. Its capture side autoconnects to
        # WirePlumber's preferred physical source. Host configurations can tune
        # that preference with dev.johnrinehart.sound.rnnoise.inputRules.
        "20-noise-suppression" = {
          "context.modules" = [
            {
              name = "libpipewire-module-filter-chain";
              flags = [ "nofail" ];
              args = {
                "node.description" = "Noise Canceled Microphone";
                "media.name" = "Noise Canceled Microphone";
                "filter.graph" = {
                  "nodes" = rnnoiseNodes;
                }
                // lib.optionalAttrs (rnnoiseLinks != [ ]) { "links" = rnnoiseLinks; }
                // lib.optionalAttrs cfg.rnnoise.dualMonoOutput.enable {
                  "outputs" = [
                    "stereo-left:Out"
                    "stereo-right:Out"
                  ];
                };
                "capture.props" = {
                  "node.name" = "capture.rnnoise";
                  "node.dont-reconnect" = false;
                  "node.passive" = true;
                  "audio.position" = [ "MONO" ];
                  "audio.rate" = 48000;
                };
                "playback.props" = {
                  "node.name" = "rnnoise_source";
                  "node.description" = "Noise Canceled Microphone";
                  "media.class" = "Audio/Source";
                  "audio.rate" = 48000;
                }
                // lib.optionalAttrs cfg.rnnoise.dualMonoOutput.enable {
                  "audio.position" = [
                    "FL"
                    "FR"
                  ];
                };
              };
            }
          ];
        };

        # Loopback for hearing your own mic through headphones (via noise suppression).
        # Keep this opt-in: USB microphones such as the Samson Q9U can provide
        # their own zero-latency hardware monitor, and running both creates an
        # echo/comb-filtered headphone signal.
        "30-mic-monitor" = lib.mkIf cfg.softwareMicMonitor.enable {
          "context.modules" = [
            {
              name = "libpipewire-module-loopback";
              args = {
                # Request a short monitor path. The hardware quantum remains the
                # floor in practice, but this prevents the loopback from adding
                # avoidable buffering on top of the RNNoise/DeepFilter chain.
                "node.description" = "Mic Monitor";
                "target.delay.sec" = 0.0;
                "capture.props" = {
                  "node.name" = "mic-monitor-capture";
                  "node.description" = "Mic Monitor";
                  "node.latency" = "128/48000";
                  "target.object" = "rnnoise_source";
                  "audio.position" =
                    if cfg.rnnoise.dualMonoOutput.enable then
                      [
                        "FL"
                        "FR"
                      ]
                    else
                      [ "MONO" ];
                };
                "playback.props" = {
                  "node.name" = "mic-monitor-playback";
                  "node.description" = "Mic Monitor";
                  "node.latency" = "128/48000";
                  "target.object" = "@DEFAULT_AUDIO_SINK@";
                  "audio.position" = [
                    "FL"
                    "FR"
                  ];
                };
              };
            }
          ];
        };
      };
    };

    # Allow the systemd user manager to grant realtime priority and memlock
    # to child services. user@.service doesn't go through PAM, so the
    # security.pam.loginLimits for @audio don't apply here.
    systemd.services."user@".serviceConfig = {
      LimitRTPRIO = 95;
      LimitNICE = "-15";
      LimitMEMLOCK = "infinity";
    };

    # Harden PipeWire against swap and resource starvation
    systemd.user.services.pipewire.serviceConfig = lib.mkMerge [
      {
        LimitMEMLOCK = "infinity";
        LimitRTPRIO = 95;
        OOMScoreAdjust = -500;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 0;
        Nice = -15;
        MemorySwapMax = "0";
        LockPersonality = true;
      }
      (lib.mkIf cfg.debug.enable {
        Environment = [ "PIPEWIRE_DEBUG=${toString cfg.debug.level}" ];
      })
    ];

    systemd.user.services.wireplumber.serviceConfig = {
      LimitMEMLOCK = "infinity";
      LimitRTPRIO = 95;
      OOMScoreAdjust = -500;
      IOSchedulingClass = "best-effort";
      IOSchedulingPriority = 0;
      Nice = -15;
      MemorySwapMax = "0";
    };

    systemd.user.services.pipewire-pulse.serviceConfig = {
      LimitMEMLOCK = "infinity";
      LimitRTPRIO = 95;
      OOMScoreAdjust = -500;
      IOSchedulingClass = "best-effort";
      IOSchedulingPriority = 0;
      Nice = -15;
      MemorySwapMax = "0";
    };

  };
}
