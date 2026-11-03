# Stage 1: answers the LUKS passphrase prompt of @volume@ once three
# factors hold, in this order:
#
#   1. Super+Alt+F on a keyboard (not shown on the console),
#   2. the TPM decrypts the bundle on the ESP (PCR 7, Secure Boot state),
#      and the face matches the model in it,
#   3. the YubiKey is touched; its hmac-secret and the TPM-held secret
#      together give the keyslot's passphrase.
#
# Any failure goes back to waiting for the chord. The typed passphrase
# keeps working throughout; the script ends once the volume is open.
#
#   unlock            the stage 1 service
#   unlock --test     one attempt now, no chord, checks the passphrase
#                     against the volume instead of answering a prompt
set -u

mode=${1:-}
run=/run/luks-fido-face
[ "$mode" = --test ] && run=$(mktemp -d /run/luks-fido-face-test.XXXXXX)
esp=$run/esp
face=$run/face
socket=$run/face.socket

log() { echo "$*"; }

# Stops the face daemon, so the camera is free, and drops its model.
stop_face() {
  if [ -n "$daemon" ]; then
    kill "$daemon" 2>/dev/null
    wait "$daemon" 2>/dev/null
    daemon=
  fi
  rm -f "$face"/*.json "$socket"
}

cleanup_attempt() {
  stop_face
  rm -f "$run/bundle.json"
}

# The encrypted bundle, copied off the ESP once. It is useless without
# this machine's TPM in the expected Secure Boot state.
fetch_bundle() {
  [ -s "$run/bundle.cred" ] && return 0
  # --test runs in stage 2, where the ESP is mounted already.
  if [ "$mode" = --test ]; then
    cp @espMountPoint@/@credPath@ "$run/bundle.cred"
    return
  fi
  [ -e @espDevice@ ] || return 1
  mkdir -p "$esp"
  mount -t vfat -o ro,umask=0077 @espDevice@ "$esp" || return 1
  cp "$esp/@credPath@" "$run/bundle.cred" 2>/dev/null
  local copied=$?
  umount "$esp"
  [ "$copied" -eq 0 ] || log "no bundle at @credPath@ on the ESP"
  return "$copied"
}

camera_node() {
  local v usb
  for v in /sys/class/video4linux/video*; do
    [ -e "$v" ] || continue
    usb=$(readlink -f "$v/device/..")
    [ "$(cat "$usb/idVendor" 2>/dev/null):$(cat "$usb/idProduct" 2>/dev/null)" = @cameraUsbId@ ] || continue
    [ "$(cat "$v/index" 2>/dev/null)" = 0 ] || continue
    echo "/dev/${v##*/}"
    return 0
  done
  return 1
}

face_matches() {
  local camera i
  camera=$(camera_node) || { log "camera @cameraUsbId@ not found"; return 1; }
  # The model goes in as root's: stage 1 knows no other user, and the
  # daemon lets root verify its own face without polkit.
  jq -c .face "$run/bundle.json" >"$face/root.json" || return 1
  pam-biometricsd \
    --device "$camera" @cameraArgs@ \
    --model-dir @modelDir@ \
    --state-dir "$face" \
    --policy @policy@ \
    --socket "$socket" &
  daemon=$!
  for i in $(seq 50); do
    [ -S "$socket" ] && break
    sleep 0.1
  done
  pam-biometrics --socket "$socket" --policy @policy@ face verify root >/dev/null
}

# The keyslot passphrase: SHA-256 of the YubiKey's hmac-secret output
# followed by the TPM-held secret, in hex.
passphrase() {
  local device hmac
  device=$(fido2-token -L | sed -n 's/^\(\/dev\/hidraw[0-9]*\): .*/\1/p' | head -n 1)
  [ -n "$device" ] || { log "no FIDO2 device"; return 1; }
  hmac=$(jq -r '.fido2 | .clientDataHash, .rp, .credential, .salt' "$run/bundle.json" |
    fido2-assert -G -h -t up=true -t uv=false -t pin=false "$device" | tail -n 1) || return 1
  [ -n "$hmac" ] || return 1
  { echo "$hmac" | base64 -d; jq -r .secret "$run/bundle.json" | base64 -d; } |
    sha256sum | cut -c1-64
}

# Sends the passphrase to the pending prompt of systemd-cryptsetup.
answer_prompt() {
  local key=$1 ask socket_path i
  for i in $(seq 100); do
    for ask in /run/systemd/ask-password/ask.*; do
      [ -e "$ask" ] || continue
      grep -q '^Id=cryptsetup:' "$ask" || continue
      grep -q '@volume@' "$ask" || continue
      socket_path=$(sed -n 's/^Socket=//p' "$ask")
      printf '+%s' "$key" | socat - "UNIX-SENDTO:$socket_path" && return 0
    done
    sleep 0.1
  done
  log "no passphrase prompt for @volume@"
  return 1
}

attempt() {
  local key
  fetch_bundle || return 1
  systemd-creds decrypt --name=@credName@ "$run/bundle.cred" "$run/bundle.json" ||
    { log "the TPM did not release the bundle"; return 1; }
  face_matches || { log "face not recognized"; return 1; }
  stop_face
  key=$(passphrase) || { log "no YubiKey touch"; return 1; }
  rm -f "$run/bundle.json"
  if [ "$mode" = --test ]; then
    printf '%s' "$key" | cryptsetup open --test-passphrase --key-file - @luksDevice@
  else
    answer_prompt "$key"
  fi
}

umask 077
mkdir -p "$run" "$face"
daemon=
trap cleanup_attempt EXIT

if [ "$mode" = --test ]; then
  trap 'cleanup_attempt; rm -rf "$run"' EXIT
  attempt && log "the volume accepts the derived passphrase"
  exit
fi

while [ ! -e /dev/mapper/@volume@ ]; do
  chord 1000 @chordKey@ || continue
  if attempt; then
    log "passphrase sent"
  fi
  cleanup_attempt
done
