# Enrolls the YubiKey, the TPM and the face model of @user@ for the stage 1
# unlock of @volume@ (unlock.sh). Run as root, with the YubiKey plugged in:
#
#   luks-fido-face-enroll
#
# It asks for two YubiKey touches (and its FIDO2 PIN if one is set) and an
# existing LUKS passphrase. It adds a keyslot, removes the keyslot of the
# previous enrollment, and writes the bundle to the ESP. Run it again after
# a face re-enrollment or a change of the Secure Boot state (PCR 7).
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

state=/var/lib/luks-fido-face
slotFile=$state/@volume@.keyslot
model=@faceStateDir@/@user@.json
bundle=@espMountPoint@/@credPath@
rp=luks-fido-face

[ -s "$model" ] || { echo "no face model for @user@ in @faceStateDir@: pam-biometrics face enroll" >&2; exit 1; }

device=$(fido2-token -L | sed -n 's/^\(\/dev\/hidraw[0-9]*\): .*/\1/p' | head -n 1)
[ -n "$device" ] || { echo "no FIDO2 device: plug the YubiKey in" >&2; exit 1; }

umask 077
tmp=$(mktemp -d /run/luks-fido-face-enroll.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
random() { head -c 32 /dev/urandom | base64 -w0; }

cdh=$(random)
echo "Touch the YubiKey to create the credential."
printf '%s\n' "$cdh" "$rp" "@volume@" "$(random)" >"$tmp/cred.in"
fido2-cred -M -h -i "$tmp/cred.in" -o "$tmp/cred.out" "$device"
credential=$(sed -n 5p "$tmp/cred.out")

salt=$(random)
echo "Touch the YubiKey again to derive the key."
hmac=$(printf '%s\n' "$cdh" "$rp" "$credential" "$salt" |
  fido2-assert -G -h -t up=true -t uv=false -t pin=false "$device" | tail -n 1)

secret=$(random)
{ echo "$hmac" | base64 -d; echo "$secret" | base64 -d; } | sha256sum | cut -c1-64 | tr -d '\n' >"$tmp/key"

# The derived key has 256 bits of entropy, so the keyslot needs no slow
# key derivation.
echo "Adding a keyslot to @luksDevice@."
cryptsetup luksAddKey --pbkdf pbkdf2 --pbkdf-force-iterations 1000 @luksDevice@ "$tmp/key"
slot=$(cryptsetup open --test-passphrase --verbose --key-file "$tmp/key" @luksDevice@ 2>&1 |
  sed -n 's/^Key slot \([0-9]*\) unlocked\./\1/p')
[ -n "$slot" ] || { echo "the new keyslot does not open @luksDevice@" >&2; exit 1; }

jq -n \
  --arg cdh "$cdh" --arg rp "$rp" --arg credential "$credential" --arg salt "$salt" \
  --arg secret "$secret" --slurpfile face "$model" \
  '{version: 1,
    fido2: {clientDataHash: $cdh, rp: $rp, credential: $credential, salt: $salt},
    secret: $secret,
    face: $face[0]}' |
  systemd-creds encrypt --with-key=tpm2 --tpm2-pcrs=7 --name=@credName@ - "$tmp/bundle.cred"
systemd-creds decrypt --name=@credName@ "$tmp/bundle.cred" - >/dev/null

mkdir -p "$(dirname "$bundle")" "$state"
cp "$tmp/bundle.cred" "$bundle.new"
mv "$bundle.new" "$bundle"

if [ -s "$slotFile" ] && [ "$(cat "$slotFile")" != "$slot" ]; then
  old=$(cat "$slotFile")
  echo "Removing keyslot $old of the previous enrollment."
  cryptsetup luksKillSlot --batch-mode --key-file "$tmp/key" @luksDevice@ "$old"
fi
echo "$slot" >"$slotFile"
echo "Enrolled in keyslot $slot. Check it with: luks-fido-face-unlock --test"
