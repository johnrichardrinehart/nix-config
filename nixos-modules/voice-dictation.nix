{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.voice-dictation;
  primaryUser = config.dev.johnrinehart.users.primary;
  usesOpenVINO =
    cfg.executionProviders.audio.provider == "openvino"
    || cfg.executionProviders.decoder.provider == "openvino";
  pathOrPackage = lib.types.oneOf [
    lib.types.package
    lib.types.path
  ];
  onnxruntimePackage =
    if usesOpenVINO then pkgs.dev.johnrinehart.onnxruntime-openvino else pkgs.onnxruntime;
  defaultModelArchitectures = pkgs.dev.johnrinehart.moonshine-models-source.modelArchMap;
  executionProviderType = lib.types.submodule {
    options = {
      provider = lib.mkOption {
        type = lib.types.enum [
          "cpu"
          "openvino"
        ];
        default = "openvino";
        description = ''
          Execution provider for this Moonshine model group. "cpu" uses ONNX
          Runtime's default CPU provider; "openvino" uses ONNX Runtime's
          OpenVINO execution provider.
        '';
      };

      device = lib.mkOption {
        type = lib.types.str;
        default = "GPU";
        description = ''
          OpenVINO device_type value, for example "GPU", "CPU", "AUTO", or a
          hardware-specific OpenVINO device string. Ignored when provider is
          "cpu".
        '';
      };

      precision = lib.mkOption {
        type = lib.types.str;
        default = "FP16";
        description = ''
          OpenVINO precision value. Ignored when provider is "cpu".
        '';
      };
    };
  };
in
{
  options.dev.johnrinehart.voice-dictation = {
    enable = lib.mkEnableOption "Moonshine-based voice dictation daemon";

    executionProviders = {
      audio = lib.mkOption {
        type = executionProviderType;
        default = {
          provider = "openvino";
          device = "GPU";
          precision = "FP16";
        };
        description = ''
          Execution provider used for the streaming frontend, encoder, and
          adapter models.
        '';
      };

      decoder = lib.mkOption {
        type = executionProviderType;
        default = {
          provider = "openvino";
          device = "GPU";
          precision = "FP16";
        };
        description = ''
          Execution provider used for the cross-KV and autoregressive decoder
          models.
        '';
      };
    };

    modelSource = lib.mkOption {
      type = pathOrPackage;
      default = pkgs.dev.johnrinehart.moonshine-models-source;
      description = ''
        Directory containing Moonshine quantized .ort model components. This
        defaults to fixed-output fetches from download.moonshine.ai, but can be
        overridden with a local derivation that copies files from a tarball or
        another offline source.
      '';
    };

    modelSourceUnfreePackageNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "moonshine-models-source" ];
      description = ''
        Unfree package names required by modelSource. Override this alongside
        modelSource when supplying a source with different licensing.
      '';
    };

    model = lib.mkOption {
      type = pathOrPackage;
      default = pkgs.dev.johnrinehart.moonshine-models-onnx.override {
        modelDir = cfg.modelSource;
      };
      description = ''
        Directory containing converted .onnx model files consumed by the
        patched Moonshine library. Override this directly if you already provide
        converted Moonshine-compatible ONNX models.
      '';
    };

    modelArch = lib.mkOption {
      type = lib.types.int;
      default = cfg.modelSource.modelArch or cfg.modelArchitectures.${cfg.modelArchName};
      description = "Moonshine model architecture id passed to moonshine_voice.";
    };

    modelArchName = lib.mkOption {
      type = lib.types.enum (builtins.attrNames cfg.modelArchitectures);
      default = cfg.modelSource.modelArchName or "medium-streaming";
      description = ''
        Named Moonshine model architecture. This is translated through
        modelArchitectures into the integer enum required by moonshine_voice.
      '';
    };

    modelArchitectures = lib.mkOption {
      type = lib.types.attrsOf lib.types.int;
      default = defaultModelArchitectures;
      description = ''
        Mapping from friendly Moonshine architecture names to native
        moonshine_voice ModelArch integer values.
      '';
    };

    audioBackend = lib.mkOption {
      type = lib.types.enum [
        "pulse"
        "sounddevice"
      ];
      default = "pulse";
      description = ''
        Audio capture backend. "pulse" records with pacat from PulseAudio's
        current default source unless inputDevice is set. "sounddevice" uses
        PortAudio/sounddevice's default input unless inputDevice is set.
      '';
    };

    inputDevice = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "@DEFAULT_SOURCE@";
      description = ''
        Optional input source name or id passed to the selected audio backend.
        Leave null to use the backend's default source.
      '';
    };

    leaderKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "KEY_RIGHTCTRL";
      example = "KEY_SPACE";
      description = ''
        Linux evdev key name that must be held while saying startPhrase. This
        does not apply to stopPhrase. Set null to allow the start phrase without
        a keyboard leader.
      '';
    };

    leaderGraceSeconds = lib.mkOption {
      type = lib.types.float;
      default = 8.0;
      description = ''
        Number of seconds after the leader key is seen during which startPhrase
        may begin dictation. This compensates for speech recognition latency
        between speaking the phrase and receiving the transcript.
      '';
    };

    startPhrase = lib.mkOption {
      type = lib.types.str;
      default = "start dictation";
      description = "Spoken phrase that starts dictation when leaderKey is active.";
    };

    stopPhrase = lib.mkOption {
      type = lib.types.str;
      default = "stop dictation";
      description = "Spoken phrase that stops dictation.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.dev.johnrinehart.whisper-voice-type.override {
        inherit (cfg) model;
        inherit (cfg) modelArch;
        inherit (cfg) audioBackend;
        inherit (cfg) inputDevice;
        inherit (cfg) leaderKey;
        inherit (cfg) leaderGraceSeconds;
        inherit (cfg) startPhrase;
        inherit (cfg) stopPhrase;
        moonshineVoice = pkgs.dev.johnrinehart.moonshine-voice.override {
          libmoonshine = pkgs.dev.johnrinehart.libmoonshine.override {
            onnxruntime = onnxruntimePackage;
            inherit (cfg) executionProviders;
          };
        };
      };
      description = "The whisper-voice-type package to use.";
    };
  };

  config = lib.mkIf cfg.enable {
    dev.johnrinehart.nix.allowedUnfreePackages = cfg.modelSourceUnfreePackageNames;

    environment.systemPackages = [
      cfg.package
      pkgs.wtype
    ];

    users.users.${primaryUser}.extraGroups = lib.mkIf (cfg.leaderKey != null) [
      "input"
    ];

    home-manager.users.${primaryUser}.systemd.user.services.moonshine-dictation = {
      Unit = {
        Description = "Moonshine voice dictation daemon";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
        X-Restart-Triggers = [ "${cfg.package}" ];
      };

      Service = {
        ExecStart = "${cfg.package}/bin/whisper-voice-type daemon";
        ExecReload = "${cfg.package}/bin/whisper-voice-type reload";
        Restart = "always";
        RestartSec = "2s";
        # Let the daemon handle SIGTERM before its capture child sees EOF.
        KillMode = "mixed";
        # Do not let a stuck inference call block graphical-session teardown.
        TimeoutStopSec = "10s";
      };

      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
