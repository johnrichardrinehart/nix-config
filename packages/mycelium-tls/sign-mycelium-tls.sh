#!/usr/bin/env bash
set -euo pipefail
umask 077

if (($# < 4)); then
  echo 'Usage: sign-mycelium-tls CA_CERT CA_KEY HOSTNAME OUTPUT_DIRECTORY [ADDITIONAL_DNS_NAMES...]' >&2
  exit 2
fi

ca_cert=$1
ca_key=$2
hostname=$3
output_directory=$4
shift 4
dns_names=("$hostname" "$@")

# Only DNS labels can enter the OpenSSL extensions file.
for name in "${dns_names[@]}"; do
  if ((${#name} > 253)) || [[ ! $name =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
    echo "sign-mycelium-tls: invalid DNS name: $name" >&2
    exit 2
  fi
  IFS=. read -r -a labels <<<"$name"
  for label in "${labels[@]}"; do
    if ((${#label} == 0 || ${#label} > 63)) || [[ $label == -* || $label == *- ]]; then
      echo "sign-mycelium-tls: invalid DNS name: $name" >&2
      exit 2
    fi
  done
done

mkdir -p -- "$output_directory"
workdir=$(mktemp -d -- "$output_directory/.sign-mycelium-tls.XXXXXXXX")
trap 'rm -rf -- "$workdir"' EXIT
trap 'exit 1' HUP INT TERM

key_file="$output_directory/server.key"
new_key=false
if [[ -e $key_file || -L $key_file ]]; then
  if [[ ! -f $key_file ]]; then
    echo 'sign-mycelium-tls: existing server.key is not a regular file' >&2
    exit 1
  fi
  chmod 0600 -- "$key_file"
else
  new_key=true
  key_file="$workdir/server.key"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$key_file"
  chmod 0600 -- "$key_file"
fi

# An empty subject avoids CN length limits; identity is exclusively in SANs.
openssl req -new -key "$key_file" -subj / -out "$workdir/server.csr"
{
  printf '%s\n' \
    'basicConstraints=critical,CA:FALSE' \
    'keyUsage=critical,digitalSignature' \
    'extendedKeyUsage=serverAuth' \
    'subjectAltName=critical,@dns_names' \
    '[dns_names]'
  index=1
  for name in "${dns_names[@]}"; do
    printf 'DNS.%d=%s\n' "$index" "$name"
    index=$((index + 1))
  done
} >"$workdir/extensions.cnf"

# Twenty bytes, with a nonzero positive prefix; no shared CA serial file.
serial="0x01$(openssl rand -hex 19)"
openssl x509 -req -in "$workdir/server.csr" \
  -CA "$ca_cert" -CAkey "$ca_key" -set_serial "$serial" \
  -days 365 -sha256 -extfile "$workdir/extensions.cnf" \
  -out "$workdir/server.crt"

# Validate before publishing; a signing failure never truncates a good leaf.
for name in "${dns_names[@]}"; do
  openssl verify -CAfile "$ca_cert" -purpose sslserver \
    -verify_hostname "$name" "$workdir/server.crt"
done
chmod 0644 -- "$workdir/server.crt"
if [[ $new_key == true ]]; then
  mv -T -- "$key_file" "$output_directory/server.key"
fi
mv -T -- "$workdir/server.crt" "$output_directory/server.crt"
printf 'Issued %s/server.crt for %s\n' "$output_directory" "$hostname"
