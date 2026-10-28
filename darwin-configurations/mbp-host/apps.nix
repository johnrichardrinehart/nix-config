# GUI apps, installed from the vendors' own signed release files.
#
# nixpkgs' darwin packages of these unpack the vendor .dmg into the store,
# which drops part of what the code signature covers (codesign: "code has no
# resources but signature indicates they must be present"), so the bundles
# lose the vendor's Team ID. macOS keys Keychain items and TCC grants (Input
# Monitoring, Accessibility) to that signature. Instead each release file is
# pinned as a fixed-output fetch and installed during activation the way a
# manual install would be: mounted and copied with ditto. The installed
# bundles are the vendors', byte for byte.
#
# An app is installed only when it is missing or older than declared, so an
# app that updated itself is never downgraded. A running app is left alone.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (pkgs) fetchurl;

  apps = {
    KeePassXC = {
      version = "2.8.0";
      bundle = "KeePassXC.app";
      src = fetchurl {
        url = "https://github.com/keepassxreboot/keepassxc/releases/download/2.8.0/KeePassXC-2.8.0-arm64.dmg";
        hash = "sha256-Ij1cca5sEdSBksaf1YL9XxAEfpHrzrwBTeM6QlOblRk=";
      };
    };
  };

  # Apps installed by hand that update themselves with Electron's Squirrel.
  # Squirrel swaps the bundle unprivileged when the user can write it;
  # otherwise it asks for an admin password every update check (hourly) to
  # run its installer as root, which then waits for the app to quit. Owning
  # the bundle keeps updates silent.
  userOwnedBundles = [
    "Proton Mail.app"
    "Proton Pass.app"
  ];
  user = config.system.primaryUser;

  sort = "${pkgs.coreutils}/bin/sort";

  installOne =
    name: app:
    let
      inherit (app) version src;
    in
    ''
      app=${lib.escapeShellArg name}
      dest=/Applications/${lib.escapeShellArg app.bundle}
      have=$(/usr/bin/defaults read "$dest/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)
      if needsInstall "$have" ${version}; then
        if /usr/bin/pgrep -qf "^$dest/Contents/MacOS/"; then
          echo "not updating $app to ${version} while it is running; quit it and re-run" >&2
        else
          echo "installing $app ${version} (have: ''${have:-none})" >&2
          /bin/rm -rf "$dest"
          copyAppFromImage ${src} ${lib.escapeShellArg app.bundle} "$dest"
        fi
      fi
    '';
in
{
  system.activationScripts.applications.text = lib.mkAfter ''
    echo "installing vendor apps..." >&2

    # needsInstall HAVE WANT: HAVE is empty or sorts before WANT.
    needsInstall() {
      [[ -z $1 ]] || { [[ $1 != "$2" ]] && [[ $(printf '%s\n' "$1" "$2" | ${sort} -V | /usr/bin/head -n1) == "$1" ]]; }
    }

    # fromImage DMG PATH CMD...: mount DMG read-only and run CMD with the
    # absolute path of PATH inside it appended.
    fromImage() {
      local image=$1 inner=$2 mnt status=0
      shift 2
      mnt=$(/usr/bin/mktemp -d)
      /usr/sbin/diskutil image attach --mountOptions nobrowse --readOnly --mountPoint "$mnt" "$image" >/dev/null
      "$@" "$mnt/$inner" || status=$?
      /usr/sbin/diskutil eject "$mnt" >/dev/null || true
      /bin/rmdir "$mnt" 2>/dev/null || true
      return "$status"
    }
    copyAppFromImage() { fromImage "$1" "$2" copyApp "$3"; }
    copyApp() { /usr/bin/ditto "$2" "$1"; }

    ${lib.concatStrings (lib.mapAttrsToList installOne apps)}

    # ownByUser BUNDLE: give the primary user an app bundle in /Applications.
    ownByUser() {
      local dest=/Applications/$1
      if [[ -d $dest ]] && [[ -n $(/usr/bin/find "$dest" ! -user ${user} -print -quit) ]]; then
        echo "giving ${user} $dest so it updates without an admin password" >&2
        /usr/sbin/chown -R ${user}:admin "$dest"
      fi
    }
    ${lib.concatMapStrings (bundle: "ownByUser ${lib.escapeShellArg bundle}\n") userOwnedBundles}
  '';
}
