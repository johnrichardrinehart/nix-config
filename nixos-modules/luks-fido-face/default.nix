# Stage 1 unlock of a LUKS volume with Super+Alt+F, a face scan and a
# YubiKey touch, gated by the TPM on the Secure Boot state (PCR 7).
#
# The keyslot passphrase is SHA-256(YubiKey hmac-secret ‖ TPM-held secret).
# The TPM-held secret, the YubiKey credential and a copy of the face model
# are in one bundle on the ESP, encrypted by systemd-creds with the TPM and
# bound to PCR 7. The face model therefore never enters the Nix store, and
# a new enrollment needs no rebuild. The face check is enforced by the
# signed stage 1 code, the other two by cryptography. The typed passphrase
# keeps working. README "LUKS unlock with a YubiKey and a face".
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.luksFidoFace;
  biometrics = config.services.pam-biometrics;
  luksDevice = config.boot.initrd.luks.devices.${cfg.volume}.device;
  espMountPoint = config.boot.loader.efi.efiSysMountPoint;
  credName = "luks-fido-face-${cfg.volume}";
  credPath = "luks-fido-face/${cfg.volume}.cred";
  # The daemon's binary wrapper only adds ffmpeg to PATH; stage 1 has
  # ffmpeg in /bin.
  daemon = "${biometrics.package}/bin/.pam-biometricsd-wrapped";
  policy = config.environment.etc."pam-biometrics/policy.json".source;
  # The two dlib models the daemon loads, as pam-biometrics packages them.
  # Stage 1 copies only listed paths, not their references, so the models
  # are named here and passed with --model-dir.
  modelDir = pkgs.runCommand "luks-fido-face-dlib-models" { } ''
    models=${pkgs.python3Packages.face-recognition-models}/${pkgs.python3.sitePackages}/face_recognition_models/models
    mkdir -p $out
    cp "$models/shape_predictor_5_face_landmarks.dat" "$models/dlib_face_recognition_resnet_model_v1.dat" $out
  '';

  chord = pkgs.runCommandCC "luks-fido-face-chord" { } ''
    mkdir -p $out/bin
    $CC -O2 -Wall -Wextra -Werror -o $out/bin/chord ${./chord.c}
  '';

  # Replaces each @name@ in `file` with the value of `name`.
  fill =
    values: file:
    lib.replaceStrings (map (name: "@${name}@") (lib.attrNames values)) (lib.attrValues values) (
      builtins.readFile file
    );
  values = {
    inherit (cfg)
      volume
      user
      espDevice
      cameraUsbId
      ;
    inherit
      luksDevice
      espMountPoint
      credName
      credPath
      ;
    policy = "${policy}";
    modelDir = "${modelDir}";
    faceStateDir = "/var/lib/private/pam-biometrics";
    # The key position that types F in the console layout: Dvorak puts F
    # on the US layout's Y.
    chordKey = if config.services.xserver.xkb.variant == "dvorak" then "21" else "33";
    cameraArgs = lib.escapeShellArgs (
      [
        "--width"
        (toString biometrics.camera.width)
        "--height"
        (toString biometrics.camera.height)
      ]
      ++ lib.optionals (biometrics.camera.inputFormat != null) [
        "--input-format"
        biometrics.camera.inputFormat
      ]
    );
  };

  unlock = pkgs.writeShellScript "luks-fido-face-unlock" (fill values ./unlock.sh);

  stage2Tools = [
    pkgs.coreutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.jq
    pkgs.libfido2
    pkgs.cryptsetup
    config.systemd.package
  ];

  # Stage 2: the unlock script with stage 2's tools, for `--test`.
  unlockTest = pkgs.writeShellApplication {
    name = "luks-fido-face-unlock";
    runtimeInputs = stage2Tools ++ [ biometrics.package ];
    text = ''exec ${unlock} "$@"'';
  };

  enroll = pkgs.writeShellApplication {
    name = "luks-fido-face-enroll";
    runtimeInputs = stage2Tools;
    text = fill values ./enroll.sh;
  };
in
{
  options.dev.johnrinehart.luksFidoFace = {
    enable = lib.mkEnableOption ''
      the stage 1 unlock of a LUKS volume with Super+Alt+F, a face scan and a
      YubiKey touch, gated by the TPM on PCR 7. `luks-fido-face-enroll`
      enrolls it'';

    volume = lib.mkOption {
      type = lib.types.str;
      default = "cryptroot";
      description = "The name of the LUKS volume in boot.initrd.luks.devices.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = config.dev.johnrinehart.users.primary;
      defaultText = lib.literalExpression "config.dev.johnrinehart.users.primary";
      description = "The user whose pam-biometrics face model the enrollment copies.";
    };

    espDevice = lib.mkOption {
      type = lib.types.str;
      default = config.fileSystems.${espMountPoint}.device;
      defaultText = lib.literalExpression "config.fileSystems.\${config.boot.loader.efi.efiSysMountPoint}.device";
      description = "The ESP's block device, which stage 1 mounts read-only to read the bundle.";
    };

    cameraUsbId = lib.mkOption {
      type = lib.types.strMatching "[0-9a-f]{4}:[0-9a-f]{4}";
      example = "32ac:001c";
      description = ''
        USB vendor and product ID of the webcam. Stage 1 has no
        /dev/v4l/by-id links, so it picks the capture node of this device.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = biometrics.enable;
        message = "dev.johnrinehart.luksFidoFace needs services.pam-biometrics (the face model and camera settings).";
      }
      {
        assertion = config.boot.initrd.systemd.enable && config.boot.initrd.systemd.tpm2.enable;
        message = "dev.johnrinehart.luksFidoFace needs systemd in stage 1 with TPM2 support.";
      }
    ];

    environment.systemPackages = [
      enroll
      unlockTest
    ];

    boot.initrd = {
      availableKernelModules = [
        "uvcvideo"
        "vfat"
        "nls_cp437"
        "nls_iso8859_1"
        "hid_generic"
        "usbhid"
      ];

      systemd = {
        initrdBin = [
          pkgs.jq
          pkgs.libfido2
          pkgs.socat
          pkgs.gnused
          pkgs.gnugrep
          pkgs.ffmpeg-headless
          chord
        ];
        extraBin = {
          systemd-creds = "${config.boot.initrd.systemd.package}/bin/systemd-creds";
          pam-biometricsd = daemon;
          pam-biometrics = "${biometrics.package}/bin/pam-biometrics";
        };
        storePaths = [
          unlock
          modelDir
          policy
        ];

        services.luks-fido-face = {
          description = "Unlock ${cfg.volume} with a face and a YubiKey";
          wantedBy = [ "cryptsetup.target" ];
          after = [ "systemd-udev-trigger.service" ];
          # Gone before resuming from hibernation and before stage 2.
          conflicts = [
            "systemd-hibernate-resume.service"
            "initrd-switch-root.target"
          ];
          before = [
            "systemd-hibernate-resume.service"
            "initrd-switch-root.target"
          ];
          unitConfig.DefaultDependencies = false;
          serviceConfig = {
            Type = "simple";
            ExecStart = unlock;
            StandardOutput = "journal";
            StandardError = "journal";
          };
        };
      };
    };
  };
}
