# secretspec on PATH, signed with a stable self-signed certificate.
#
# secretspec's KeePassXC master password lives in the login keychain, whose
# items admit programs by code signature twice over: the access list ("wants
# to use your confidential information") and the partition list ("wants to
# access key"). Nix builds are only ad hoc signed, so every build is a new
# program to both and asks twice. Signed with one certificate, every build
# matches the access-list entry "Always Allow" records (`identifier secretspec
# and certificate leaf = H"…"`); the partition list still records each build's
# cdhash, so a new build asks once, "access key", and later runs not at all.
#
# The private key must not enter /nix/store (world-readable, and copied to
# caches), so the build stays unsigned and `provision-mac` signs a copy outside
# the store, as the primary user, with MAC_CODESIGN_IDENTITY_PEM_BASE64 from
# the environment it was started from: base64 of one PEM holding the
# certificate and its private key. Without it the copy is the unsigned build,
# and a manual step says so.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  user = config.system.primaryUser;
  stateDir = "${config.users.users.${user}.home}/.local/state/secretspec-signed";
  signed = "${stateDir}/bin/secretspec";
  secretspec = pkgs.callPackage ../../packages/secretspec/package.nix { };
  unsigned = lib.getExe secretspec;

  # A link to the signed copy, beside the build it is copied from: keeping the
  # build in the system closure keeps the store libraries the copy links.
  onPath =
    pkgs.runCommand "secretspec-signed-${secretspec.version}"
      {
        meta.mainProgram = "secretspec";
      }
      ''
        mkdir -p $out/bin $out/share/secretspec-signed
        ln -s ${lib.escapeShellArg signed} $out/bin/secretspec
        ln -s ${secretspec} $out/share/secretspec-signed/unsigned
      '';
in
{
  home-manager.users.${user}.home.packages = [ onPath ];

  dev.johnrinehart.provisionMac.userSteps."signing secretspec" = ''
    state=${lib.escapeShellArg stateDir}
    signed=${lib.escapeShellArg signed}
    unsigned=${unsigned}
    identity=''${MAC_CODESIGN_IDENTITY_PEM_BASE64:-}
    current() { [[ -x $signed && $(cat "$state/source" 2>/dev/null) == "$unsigned" ]]; }

    tmp=$(mktemp -d)
    keychain=$tmp/sign.keychain-db
    trap '/usr/bin/security delete-keychain "$keychain" 2>/dev/null || true; rm -rf "$tmp"' EXIT
    cp "$unsigned" "$tmp/secretspec"
    chmod u+w "$tmp/secretspec"

    if [[ -n $identity ]]; then
      (umask 077 && /usr/bin/base64 -d <<<"$identity" >"$tmp/identity.pem")
      # A throwaway keychain (not added to the search list) that only codesign
      # may use without asking.
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
      if current && /usr/bin/codesign -d -r- "$signed" 2>&1 | grep -qi "certificate leaf = H\"$leaf\""; then
        echo "$signed is already this build, signed"
        exit 0
      fi
      /usr/bin/codesign --force --keychain "$keychain" -s "$leaf" -i secretspec "$tmp/secretspec"
      echo "signed $unsigned as $signed"
    elif current; then
      exit 0
    else
      echo "MAC_CODESIGN_IDENTITY_PEM_BASE64 is not set; installing $unsigned unsigned" >&2
    fi

    # Replace within the directory, so secretspec is never missing or partial.
    mkdir -p "$state/bin"
    cp "$tmp/secretspec" "$state/bin/.secretspec.new"
    mv -f "$state/bin/.secretspec.new" "$signed"
    echo "$unsigned" >"$state/source"
  '';

  dev.johnrinehart.provisionMac.manualSteps."secretspec: code signing" = {
    check = ''
      [[ $(cat ${lib.escapeShellArg stateDir}/source) == ${unsigned} ]] &&
        /usr/bin/codesign -d -r- ${lib.escapeShellArg signed} 2>&1 | grep -q 'certificate leaf'
    '';
    instructions = ''
      ${signed} is not signed with your certificate, so every secretspec
      build asks the keychain twice. Run provision-mac again where
      MAC_CODESIGN_IDENTITY_PEM_BASE64 is set (base64 of one PEM with a
      self-signed code-signing certificate and its private key), e.g. from a
      checkout whose direnv exports it from secretspec.
    '';
  };
}
