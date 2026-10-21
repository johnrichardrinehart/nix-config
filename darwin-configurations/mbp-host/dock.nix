# Dock preferences, applied without restarting the Dock unless they change.
#
# nix-darwin's system.defaults.dock writes the preferences and then kills the
# Dock on every activation, changed or not. The Dock also runs Spaces and
# Mission Control, so each restart reshuffles windows across Spaces and
# displays. Here each preference is compared with what the Dock has and only
# written when it differs; the Dock is restarted only after such a write.
{ config, lib, ... }:
let
  user = config.system.primaryUser;

  settings = {
    orientation = "left";
    tilesize = 78;
    autohide = false;
    # The tiles are left to the Dock itself: nix-darwin would replace the
    # whole list, including apps this configuration does not install.
  };

  # What `defaults read` prints for a value, and the arguments that write it.
  shown = value: if lib.isBool value then (if value then "1" else "0") else toString value;
  typed =
    value:
    if lib.isBool value then
      "-bool ${lib.boolToString value}"
    else if lib.isInt value then
      "-int ${toString value}"
    else
      "-string ${lib.escapeShellArg value}";

  asUser = ''launchctl asuser "$(id -u -- ${user})" sudo --user=${user} --'';
in
{
  system.activationScripts.userDefaults.text = lib.mkAfter ''
    dockChanged=
    ${lib.concatStrings (
      lib.mapAttrsToList (key: value: ''
        if [[ $(${asUser} defaults read com.apple.dock ${key} 2>/dev/null) != ${lib.escapeShellArg (shown value)} ]]; then
          ${asUser} defaults write com.apple.dock ${key} ${typed value}
          dockChanged=1
        fi
      '') settings
    )}
    if [[ -n $dockChanged ]]; then
      echo >&2 "restarting Dock for changed preferences..."
      killall -qu ${user} Dock || true
    fi
  '';
}
