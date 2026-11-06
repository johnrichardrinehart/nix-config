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

  # Apps that must have a Dock tile, by bundle identifier and path. A missing
  # tile is added at the end; the other tiles and their order stay as they
  # are. An app that is not installed gets no tile.
  apps = {
    "com.brave.Browser.origin" = "/Applications/Brave Origin.app";
  };

  tile =
    path:
    "<dict><key>tile-data</key><dict><key>file-data</key><dict>"
    + "<key>_CFURLString</key><string>${path}</string>"
    + "<key>_CFURLStringType</key><integer>0</integer>"
    + "</dict></dict><key>tile-type</key><string>file-tile</string></dict>";

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
    dockApps=$(${asUser} defaults read com.apple.dock persistent-apps 2>/dev/null || true)
    ${lib.concatStrings (
      lib.mapAttrsToList (id: path: ''
        if [[ -d ${lib.escapeShellArg path} ]] && [[ $dockApps != *${lib.escapeShellArg "\"bundle-identifier\" = \"${id}\";"}* ]]; then
          echo >&2 ${lib.escapeShellArg "adding ${path} to the Dock..."}
          ${asUser} defaults write com.apple.dock persistent-apps -array-add ${lib.escapeShellArg (tile path)}
          dockChanged=1
        fi
      '') apps
    )}
    if [[ -n $dockChanged ]]; then
      echo >&2 "restarting Dock for changed preferences..."
      killall -qu ${user} Dock || true
    fi
  '';
}
