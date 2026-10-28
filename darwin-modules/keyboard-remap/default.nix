# keyboard-remap (packages/keyboard-remap): per-keyboard key remaps and
# per-app key rules for macOS without a driver extension, which device
# management can forbid (an MDM system-extension allow list).
#
# Device remaps set each matching keyboard's UserKeyMapping in the HID event
# system from a root launch daemon: no driver and no privacy grant, and they
# hold at the login window and in secure input fields. A per-user launch
# agent shows a menu bar item that pauses and resumes all remapping (for
# when someone else uses the machine), and runs the app rules with a session
# event tap, which sees keys after the device remaps and needs Accessibility.
# `keyboard-remap pause|resume|status` does the same from a shell.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.dev.johnrinehart.keyboardRemap;
  keys = import ./keys.nix;
  keyName = types.enum (lib.attrNames keys);
  modifier = types.enum [
    "caps_lock"
    "shift"
    "control"
    "option"
    "command"
  ];
  # Key events carry no press or release of these, only flag changes.
  modifierKeys = [
    "caps_lock"
    "left_control"
    "left_shift"
    "left_option"
    "left_command"
    "right_control"
    "right_shift"
    "right_option"
    "right_command"
  ];

  configFile = pkgs.writeText "keyboard-remap.json" (
    builtins.toJSON {
      devices = builtins.map (remap: {
        inherit (remap) description match;
        map = lib.mapAttrsToList (from: to: [
          keys.${from}.usage
          keys.${to}.usage
        ]) remap.map;
      }) cfg.deviceRemaps;
      apps = builtins.map (rule: {
        inherit (rule) description;
        frontmostApplication = {
          inherit (rule.frontmostApplication) filePaths bundleIdentifiers;
        };
        inherit (keys.${rule.key}) keyCode;
        inherit (rule.modifiers) mandatory;
        optional = lib.remove "any" rule.modifiers.optional;
        anyOptional = lib.elem "any" rule.modifiers.optional;
      }) cfg.appRules;
    }
  );
in
{
  options.dev.johnrinehart.keyboardRemap = {
    enable = lib.mkEnableOption "per-keyboard key remaps and per-app swallowed keys";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../../packages/keyboard-remap { };
      defaultText = lib.literalExpression "pkgs.callPackage ../../packages/keyboard-remap { }";
      description = "The keyboard-remap build.";
    };

    agentProgram = mkOption {
      type = types.str;
      default = lib.getExe cfg.package;
      defaultText = lib.literalExpression "lib.getExe package";
      description = ''
        Executable the app-rule agent runs. Its Accessibility grant follows
        the code signature, so point this at a copy signed with a stable
        certificate to keep the grant across rebuilds.
      '';
    };

    deviceRemaps = mkOption {
      default = [ ];
      description = ''
        Key remaps for the keyboards whose HID service properties match. A
        keyboard several remaps match gets all of their keys; a keyboard none
        match gets an empty UserKeyMapping, which also clears one set by hand
        with `hidutil`. `hidutil list` shows the properties.
      '';
      type = types.listOf (
        types.submodule {
          options = {
            description = mkOption {
              type = types.str;
              description = "What the remap is for, as logged.";
            };
            match = mkOption {
              type = types.attrsOf (
                types.oneOf [
                  types.bool
                  types.int
                  types.str
                ]
              );
              example = {
                VendorID = 7504;
                ProductID = 24926;
              };
              description = ''
                HID service properties the keyboard must have, all of them,
                e.g. `{ "Built-In" = true; }` for the built-in keyboard.
              '';
            };
            map = mkOption {
              type = types.attrsOf keyName;
              example = {
                caps_lock = "escape";
              };
              description = "Key names (keys.nix): from = to.";
            };
          };
        }
      );
    };

    appRules = mkOption {
      default = [ ];
      description = ''
        Keys swallowed while an app is frontmost: neither the press, its
        repeats nor its release reach any app. The key is the one apps see,
        after `deviceRemaps`.
      '';
      type = types.listOf (
        types.submodule {
          options = {
            description = mkOption {
              type = types.str;
              description = "What the rule is for.";
            };
            frontmostApplication = {
              filePaths = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = "Regular expressions (ICU) on the frontmost app's executable path.";
              };
              bundleIdentifiers = mkOption {
                type = types.listOf types.str;
                default = [ ];
                description = ''
                  Regular expressions (ICU) on the frontmost app's bundle
                  identifier. A rule with neither list applies in every app.
                '';
              };
            };
            key = mkOption {
              type = keyName;
              description = "Key name (keys.nix); not a modifier.";
            };
            modifiers = {
              mandatory = mkOption {
                type = types.listOf modifier;
                default = [ ];
                description = "Modifiers that must be held. Either side counts.";
              };
              optional = mkOption {
                type = types.listOf (types.either modifier (types.enum [ "any" ]));
                default = [ ];
                description = ''
                  Modifiers that may be held too; any other held modifier
                  stops the match. "any" allows all. Fn is ignored.
                '';
              };
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      builtins.map (remap: {
        assertion = lib.all (from: keys ? ${from}) (lib.attrNames remap.map);
        message = "keyboardRemap.deviceRemaps \"${remap.description}\": unknown keys ${
          lib.concatStringsSep ", " (lib.filter (from: !(keys ? ${from})) (lib.attrNames remap.map))
        }";
      }) cfg.deviceRemaps
      ++ builtins.map (rule: {
        assertion = !lib.elem rule.key modifierKeys;
        message = "keyboardRemap.appRules \"${rule.description}\": ${rule.key} is a modifier key";
      }) cfg.appRules;

    # `keyboard-remap pause|resume|status` from a shell.
    environment.systemPackages = [ cfg.package ];

    launchd.daemons.keyboard-remap-devices = lib.mkIf (cfg.deviceRemaps != [ ]) {
      serviceConfig = {
        ProgramArguments = [
          (lib.getExe cfg.package)
          "devices"
          "${configFile}"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardErrorPath = "/var/log/keyboard-remap.log";
      };
    };

    # Always: it carries the pause item even without app rules.
    launchd.user.agents.keyboard-remap-apps = {
      serviceConfig = {
        ProgramArguments = [
          cfg.agentProgram
          "apps"
          "${configFile}"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Interactive";
        StandardErrorPath = "/tmp/keyboard-remap.log";
      };
    };
  };
}
