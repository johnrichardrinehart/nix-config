# Copies the Secure Boot keys of an installed Framework 13 Pro into a
# KeePassXC database, through secretspec, and reads them back to compare. Run
# it from a checkout whose secretspec.toml declares the FRAMEWORK_13_PRO_SECURE_BOOT_*
# keys below and a `framework-13-pro-secure-boot` scope that lists them. The
# laptop makes the keys on its first boot
# (nixos-configurations/framework-13-pro/endpoint-security.nix); only root
# can read them, so this asks for the laptop's sudo password.
#
# It uses the secretspec on PATH: on the Mac that is the signed copy, which
# the keychain trusts.
{
  coreutils,
  gnutar,
  openssh,
  writeShellApplication,
}:
writeShellApplication {
  name = "framework-13-pro-secure-boot-keys";
  runtimeInputs = [
    coreutils
    gnutar
    openssh
  ];
  text = ''
    usage() {
      cat <<EOF
    Usage: framework-13-pro-secure-boot-keys SSH-DESTINATION

    Run from a checkout whose secretspec.toml declares the keys. Copies /var/lib/sbctl
    (GUID, and the PK, KEK and db keys and certificates) from
    SSH-DESTINATION into KeePassXC with secretspec, then reads the values
    back and compares them with the copies from the laptop.
    EOF
    }

    if [ "$#" != 1 ] || [ "$1" = -h ] || [ "$1" = --help ]; then
      usage >&2
      exit 64
    fi
    dest=$1

    if [ ! -f secretspec.toml ]; then
      echo "framework-13-pro-secure-boot-keys: run from a checkout with a secretspec.toml" >&2
      exit 1
    fi
    command -v secretspec >/dev/null || {
      echo "framework-13-pro-secure-boot-keys: secretspec is not on PATH" >&2
      exit 1
    }

    # secretspec key, then the file below /var/lib/sbctl.
    entries=(
      FRAMEWORK_13_PRO_SECURE_BOOT_GUID GUID
      FRAMEWORK_13_PRO_SECURE_BOOT_PK_KEY keys/PK/PK.key
      FRAMEWORK_13_PRO_SECURE_BOOT_PK_CERT keys/PK/PK.pem
      FRAMEWORK_13_PRO_SECURE_BOOT_KEK_KEY keys/KEK/KEK.key
      FRAMEWORK_13_PRO_SECURE_BOOT_KEK_CERT keys/KEK/KEK.pem
      FRAMEWORK_13_PRO_SECURE_BOOT_DB_KEY keys/db/db.key
      FRAMEWORK_13_PRO_SECURE_BOOT_DB_CERT keys/db/db.pem
    )
    keys=()
    files=()
    for ((i = 0; i < ''${#entries[@]}; i += 2)); do
      keys+=("''${entries[i]}")
      files+=("''${entries[i + 1]}")
    done
    resources=$(IFS=,; echo "''${keys[*]}")

    umask 077
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT

    IFS= read -rsp "sudo password of $dest: " password
    echo
    printf '%s\n' "$password" |
      ssh "$dest" sudo -S -p "" tar -C /var/lib/sbctl -cf - "''${files[@]}" >"$work/sbctl.tar"
    unset password
    mkdir "$work/sbctl"
    tar -C "$work/sbctl" -xf "$work/sbctl.tar"

    who=(--caller framework-13-pro-secure-boot-keys --caller-operation "escrow Secure Boot keys of $dest")
    for ((i = 0; i < ''${#keys[@]}; i++)); do
      secretspec set -f secretspec.toml --from-file "$work/sbctl/''${files[i]}" \
        --reason "store the Secure Boot key file ''${files[i]} of $dest" \
        "''${who[@]}" --caller-resource "''${keys[i]}" "''${keys[i]}"
      echo "stored ''${keys[i]}"
    done

    # One unlock for all of them; the child compares hashes, never values.
    export SB_KEYS_WORK=$work
    # shellcheck disable=SC2016 # the child script expands its own variables
    secretspec run -f secretspec.toml -S framework-13-pro-secure-boot \
      --reason "check the Secure Boot keys of $dest that were just stored" \
      "''${who[@]}" --caller-resource "$resources" -- \
      bash -c '
        set -euo pipefail
        status=0
        while [ "$#" -gt 0 ]; do
          stored=$(printf "%s" "''${!1}" | sha256sum)
          laptop=$(sha256sum <"$SB_KEYS_WORK/sbctl/$2")
          if [ "$stored" = "$laptop" ]; then
            echo "match $1"
          else
            echo "MISMATCH $1" >&2
            status=1
          fi
          shift 2
        done
        exit "$status"
      ' _ "''${entries[@]}"
  '';
}
