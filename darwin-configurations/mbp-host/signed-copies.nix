# Programs run from a copy outside /nix/store, signed with a stable
# self-signed certificate.
#
# macOS remembers what a user allowed a program to do by its code signature:
# keychain items (access list and partition list) and privacy grants such as
# Accessibility. Nix builds are only ad hoc signed, so every build is a new
# program that asks again, and every Accessibility grant leaves an entry for
# its store path behind. A copy at a fixed path signed with one certificate
# satisfies the requirement recorded at the first grant
# (`identifier <name> and certificate leaf = H"…"`) across rebuilds.
#
# The private key must not enter /nix/store (world-readable, and copied to
# caches), so the builds stay unsigned and `provision-mac` signs the copies,
# as the primary user, with MAC_CODESIGN_IDENTITY_PEM_BASE64 from the
# environment it was started from: base64 of one PEM holding the certificate
# and its private key. Without it the copies are the unsigned builds, and a
# manual step says so.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.dev.johnrinehart.mbp-host.signedCopies;
  user = config.system.primaryUser;
  home = config.users.users.${user}.home;
  esc = lib.escapeShellArg;
in
{
  options.dev.johnrinehart.mbp-host.signedCopies = mkOption {
    default = { };
    description = "Programs `provision-mac` installs as signed copies, by name (also their signing identifier).";
    type = types.attrsOf (
      types.submodule (
        { name, config, ... }:
        {
          options = {
            package = mkOption {
              type = types.package;
              description = "Build to copy; kept in the system closure, with the store libraries the copy links.";
            };
            executable = mkOption {
              type = types.str;
              default = lib.getExe config.package;
              defaultText = lib.literalExpression "lib.getExe package";
              description = "Executable within `package` to copy.";
            };
            launchdLabel = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Launch agent restarted when the copy changes, since its arguments (the copy's path) do not.";
            };
            path = mkOption {
              type = types.str;
              readOnly = true;
              default = "${home}/.local/state/${name}-signed/bin/${name}";
              description = "Where the copy is installed.";
            };
            link = mkOption {
              type = types.package;
              readOnly = true;
              default = pkgs.runCommand "${name}-signed" { meta.mainProgram = name; } ''
                mkdir -p $out/bin
                ln -s ${esc config.path} $out/bin/${name}
              '';
              description = "Package with `bin/<name>` linking to the copy, for PATH.";
            };
          };
        }
      )
    );
  };

  config = lib.mkIf (cfg != { }) {
    environment.etc = lib.mapAttrs' (
      name: copy: lib.nameValuePair "signed-copies/${name}" { source = copy.package; }
    ) cfg;

    dev.johnrinehart.provisionMac.userSteps."signing ${lib.concatStringsSep ", " (lib.attrNames cfg)}" =
    ''
      identity=''${MAC_CODESIGN_IDENTITY_PEM_BASE64:-}
      tmp=$(mktemp -d)
      keychain=$tmp/sign.keychain-db
      trap '/usr/bin/security delete-keychain "$keychain" 2>/dev/null || true; rm -rf "$tmp"' EXIT

      leaf=
      if [[ -n $identity ]]; then
        (umask 077 && /usr/bin/base64 -d <<<"$identity" >"$tmp/identity.pem")
        # A throwaway keychain (not added to the search list) that only
        # codesign may use without asking.
        password=$(/usr/bin/uuidgen)
        /usr/bin/security create-keychain -p "$password" "$keychain"
        /usr/bin/security unlock-keychain -p "$password" "$keychain"
        /usr/bin/security import "$tmp/identity.pem" -k "$keychain" -T /usr/bin/codesign >/dev/null
        /usr/bin/security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null
        # The certificate's SHA-1, which is also the hash the requirement pins.
        leaf=$(/usr/bin/security find-identity -p codesigning "$keychain" | /usr/bin/awk '$1 == "1)" { print $2; exit }')
        if [[ -z $leaf ]]; then
          echo "MAC_CODESIGN_IDENTITY_PEM_BASE64 holds no code-signing identity" >&2
          exit 1
        fi
      else
        echo "MAC_CODESIGN_IDENTITY_PEM_BASE64 is not set; installing new builds unsigned" >&2
      fi

      # install_copy NAME UNSIGNED COPY LAUNCHD-LABEL
      install_copy() {
        local name=$1 unsigned=$2 copy=$3 label=$4
        local state
        state=$(dirname "$(dirname "$copy")")
        local current=
        if [[ -x $copy && $(cat "$state/source" 2>/dev/null) == "$unsigned" ]]; then
          current=1
        fi
        if [[ -n $leaf ]]; then
          if [[ -n $current ]] && /usr/bin/codesign -d -r- "$copy" 2>&1 | grep -qi "certificate leaf = H\"$leaf\""; then
            echo "$copy is already this build, signed"
            return
          fi
        elif [[ -n $current ]]; then
          return
        fi
        cp "$unsigned" "$tmp/$name"
        chmod u+w "$tmp/$name"
        if [[ -n $leaf ]]; then
          /usr/bin/codesign --force --keychain "$keychain" -s "$leaf" -i "$name" "$tmp/$name"
          echo "signed $unsigned as $copy"
        fi
        # Replace within the directory, so the copy is never missing or partial.
        mkdir -p "$(dirname "$copy")"
        cp "$tmp/$name" "$copy.new"
        mv -f "$copy.new" "$copy"
        echo "$unsigned" >"$state/source"
        if [[ -n $label ]]; then
          /bin/launchctl kickstart -k "gui/$(id -u)/$label" || true
        fi
      }
    ''
    + lib.concatStrings (
      lib.mapAttrsToList (name: copy: ''
        install_copy ${esc name} ${esc copy.executable} ${esc copy.path} ${esc (toString copy.launchdLabel)}
      '') cfg
    );

    dev.johnrinehart.provisionMac.manualSteps."code signing" = {
      check =
        lib.concatStrings (
          lib.mapAttrsToList (_: copy: ''
            [[ $(cat ${esc (dirOf (dirOf copy.path))}/source) == ${esc copy.executable} ]] &&
              /usr/bin/codesign -d -r- ${esc copy.path} 2>&1 | grep -q 'certificate leaf' &&
          '') cfg
        )
        + "true";
      instructions = ''
        These copies are not signed with your certificate, so macOS treats each
        build as a new program (keychain prompts, Accessibility grants):
      ''
      + lib.concatMapStrings (copy: "  ${copy.path}\n") (lib.attrValues cfg)
      + ''
        Run provision-mac again where MAC_CODESIGN_IDENTITY_PEM_BASE64 is set
        (base64 of one PEM with a self-signed code-signing certificate and its
        private key), e.g. from a checkout whose direnv exports it from
        secretspec.
      '';
    };
  };
}
