{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.cloudflareDdns;

  ddnsCli = pkgs.writeScriptBin "uz801-cf-ddns" ''
    #!/bin/sh
    # Update a Cloudflare DNS A record with the current public IPv4 address.
    # Reads CF_API_TOKEN (and optional CF_RECORD_NAME, CF_ZONE_ID, CF_ZONE_NAME,
    # CF_TTL, CF_PROXIED) from ${cfg.envFile} so secrets stay off /nix/store.
    set -eu

    FORCE=0
    if [ "''${1:-}" = "--force" ] || [ "''${1:-}" = "-f" ]; then
      FORCE=1
    fi

    ENV_FILE=${lib.escapeShellArg cfg.envFile}
    TOKEN_FILE=${lib.escapeShellArg (if cfg.tokenFile != null then cfg.tokenFile else "")}
    CACHE_FILE="/run/cf-ddns.last_ip"
    CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"

    log() {
      printf 'uz801-cf-ddns: %s\n' "$1" >&2
      logger -t uz801-cf-ddns "$1" 2>/dev/null || true
    }

    if [ -r "$ENV_FILE" ]; then
      # shellcheck disable=SC1090
      . "$ENV_FILE"
    fi

    CF_API_TOKEN="''${CF_API_TOKEN:-}"
    if [ -z "$CF_API_TOKEN" ] && [ -n "$TOKEN_FILE" ] && [ -r "$TOKEN_FILE" ]; then
      CF_API_TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")
    fi
    CF_RECORD_NAME="''${CF_RECORD_NAME:-${if cfg.recordName != null then cfg.recordName else ""}}"
    CF_ZONE_ID="''${CF_ZONE_ID:-}"
    CF_ZONE_NAME="''${CF_ZONE_NAME:-${if cfg.zoneName != null then cfg.zoneName else ""}}"
    CF_TTL="''${CF_TTL:-${toString cfg.ttl}}"
    CF_PROXIED="''${CF_PROXIED:-${if cfg.proxied then "true" else "false"}}"

    if [ -z "$CF_API_TOKEN" ] || [ -z "$CF_RECORD_NAME" ]; then
      log "waiting for CF_API_TOKEN ($TOKEN_FILE / $ENV_FILE) and CF_RECORD_NAME"
      exit 0
    fi

    is_ipv4() {
      printf '%s\n' "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
    }

    fetch_public_ip() {
      for url in ${lib.concatMapStringsSep " " lib.escapeShellArg cfg.ipUrls}; do
        ip_val=$(curl -4fsS --cacert "$CA_BUNDLE" --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if is_ipv4 "$ip_val"; then
          printf '%s\n' "$ip_val"
          return 0
        fi
      done
      return 1
    }

    # Pass Authorization header via stdin (-K -) so CF_API_TOKEN never appears in /proc/*/cmdline.
    cf_api() {
      method="$1"
      path="$2"
      data="''${3:-}"
      if [ -n "$data" ]; then
        printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$CF_API_TOKEN" \
          | curl -fsS --cacert "$CA_BUNDLE" --max-time 15 -K - -X "$method" \
              "https://api.cloudflare.com/client/v4$path" --data "$data"
      else
        printf 'header = "Authorization: Bearer %s"\n' "$CF_API_TOKEN" \
          | curl -fsS --cacert "$CA_BUNDLE" --max-time 15 -K - -X "$method" \
              "https://api.cloudflare.com/client/v4$path"
      fi
    }

    json_first_str() {
      key="$1"
      sed -n "s/.*\"$key\":\"\([^\"]*\)\".*/\1/p" | head -n 1
    }

    pub_ip=$(fetch_public_ip || true)
    if [ -z "$pub_ip" ]; then
      log "failed to determine public IPv4 address"
      exit 1
    fi

    if [ "$FORCE" -eq 0 ] && [ -r "$CACHE_FILE" ]; then
      cached_ip=$(cat "$CACHE_FILE" 2>/dev/null || true)
      if [ "$cached_ip" = "$pub_ip" ]; then
        exit 0
      fi
    fi

    # Resolve CF_ZONE_ID automatically if not provided in envFile.
    if [ -z "$CF_ZONE_ID" ]; then
      candidate="''${CF_ZONE_NAME:-$CF_RECORD_NAME}"
      while [ -n "$candidate" ]; do
        resp=$(cf_api GET "/zones?name=$candidate&status=active" 2>/dev/null || true)
        zid=$(printf '%s\n' "$resp" | sed -n 's/.*"result":\[{"id":"\([^"]*\)".*/\1/p' | head -n 1)
        if [ -n "$zid" ]; then
          CF_ZONE_ID="$zid"
          break
        fi
        case "$candidate" in
          *.*) candidate="''${candidate#*.}" ;;
          *) break ;;
        esac
      done
      if [ -z "$CF_ZONE_ID" ]; then
        log "could not resolve Cloudflare zone ID for $CF_RECORD_NAME (set CF_ZONE_ID in $ENV_FILE if token lacks Zone:Read)"
        exit 1
      fi
    fi

    lookup=$(cf_api GET "/zones/$CF_ZONE_ID/dns_records?type=A&name=$CF_RECORD_NAME")
    if ! printf '%s\n' "$lookup" | grep -q '"success":true'; then
      log "Cloudflare record lookup failed for $CF_RECORD_NAME"
      exit 1
    fi

    rec_id=$(printf '%s\n' "$lookup" | sed -n 's/.*"result":\[{"id":"\([^"]*\)".*/\1/p' | head -n 1)
    rec_ip=$(printf '%s\n' "$lookup" | json_first_str content)
    payload="{\"type\":\"A\",\"name\":\"$CF_RECORD_NAME\",\"content\":\"$pub_ip\",\"ttl\":$CF_TTL,\"proxied\":$CF_PROXIED}"

    if [ -n "$rec_id" ]; then
      if [ "$rec_ip" = "$pub_ip" ]; then
        printf '%s\n' "$pub_ip" > "$CACHE_FILE"
        log "$CF_RECORD_NAME already points to $pub_ip"
        exit 0
      fi
      upd=$(cf_api PATCH "/zones/$CF_ZONE_ID/dns_records/$rec_id" "$payload")
      if printf '%s\n' "$upd" | grep -q '"success":true'; then
        printf '%s\n' "$pub_ip" > "$CACHE_FILE"
        log "updated $CF_RECORD_NAME: $rec_ip -> $pub_ip"
        exit 0
      fi
      log "failed to update $CF_RECORD_NAME to $pub_ip"
      exit 1
    else
      crt=$(cf_api POST "/zones/$CF_ZONE_ID/dns_records" "$payload")
      if printf '%s\n' "$crt" | grep -q '"success":true'; then
        printf '%s\n' "$pub_ip" > "$CACHE_FILE"
        log "created $CF_RECORD_NAME -> $pub_ip"
        exit 0
      fi
      log "failed to create $CF_RECORD_NAME -> $pub_ip"
      exit 1
    fi
  '';
  ddnsRun = pkgs.writeScript "cloudflare-ddns-run" ''
    #!/bin/sh
    while ( [ ! -r ${lib.escapeShellArg cfg.envFile} ] ${
      lib.optionalString (cfg.tokenFile != null) "&& [ ! -r ${lib.escapeShellArg cfg.tokenFile} ]"
    } ) \
       || [ ! -s /etc/resolv.conf ] \
       || ! ip -4 route show default 2>/dev/null | grep -q '^default'; do
      sleep 2
    done

    # Wait briefly for ntpd so TLS certificate verification succeeds on RTC-less boot.
    waited=0
    while [ "$(date +%Y)" -lt 2025 ] && [ "$waited" -lt 20 ]; do
      sleep 0.5
      waited=$((waited + 1))
    done

    net_state() {
      {
        ip -4 -o addr show 2>/dev/null
        ip -4 route show default 2>/dev/null
      } | tr '\n' ';'
    }

    run_ddns() {
      if ${ddnsCli}/bin/uz801-cf-ddns "$@"; then
        echo ok > /run/cf-ddns.status
      else
        echo fail > /run/cf-ddns.status
      fi
    }

    # Trigger immediately on startup.
    last_net=$(net_state)
    last_check=$(date +%s)
    run_ddns --force

    # Watch for local IPv4 address/route changes every 5s (zero network traffic)
    # and poll upstream public IP every checkIntervalSec for ISP WAN IP changes.
    while true; do
      sleep 5
      cur_net=$(net_state)
      now=$(date +%s)
      if [ "$cur_net" != "$last_net" ]; then
        last_net="$cur_net"
        if ip -4 route show default 2>/dev/null | grep -q '^default'; then
          last_check="$now"
          run_ddns --force
        fi
      elif [ $((now - last_check)) -ge ${toString cfg.checkIntervalSec} ]; then
        last_check="$now"
        run_ddns
      fi
    done
  '';
in
{
  options.dev.johnrinehart.cloudflareDdns = {
    enable = lib.mkEnableOption "Cloudflare dynamic DNS A-record updater for MixOS";

    recordName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional default DNS A record FQDN (can also be set via CF_RECORD_NAME in envFile).";
    };

    zoneName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional Cloudflare zone name for auto-lookup (or set CF_ZONE_ID in envFile).";
    };

    ttl = lib.mkOption {
      type = lib.types.int;
      default = 120;
      description = "DNS record TTL in seconds.";
    };

    proxied = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether Cloudflare proxies the record (must be false for Nebula UDP traffic).";
    };

    checkIntervalSec = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Periodic public-IP check interval in seconds (in addition to startup and network-change triggers).";
    };

    sopsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Optional SOPS file providing the Cloudflare API token key deployed to /state/secrets.";
    };

    sopsKey = lib.mkOption {
      type = lib.types.str;
      default = "cloudflare-api-token";
      description = "Top-level YAML key inside sopsFile holding the Cloudflare API token.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional file containing only the Cloudflare API token (wired automatically when sopsFile is set).";
    };

    envFile = lib.mkOption {
      type = lib.types.str;
      default = "/state/cloudflare-ddns.env";
      description = "Optional on-device 0600 shell env file providing or overriding CF_API_TOKEN, CF_RECORD_NAME, or CF_ZONE_ID.";
    };

    ipUrls = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "https://ipv4.wtfismyip.com/text"
        "https://api.ipify.org"
      ];
      description = "Ordered HTTPS endpoints queried for the current public IPv4 address.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        packages = [ ddnsCli ];
        services.cloudflare-ddns.run = ddnsRun;
      }
      (lib.optionalAttrs (options ? sops) {
        sops.secrets = lib.mkIf (cfg.sopsFile != null) {
          cloudflare-api-token = {
            inherit (cfg) sopsFile;
            key = cfg.sopsKey;
            mode = "0400";
            optional = true;
          };
        };
      })
      (lib.mkIf (cfg.sopsFile != null) {
        assertions = [
          {
            assertion = options ? sops;
            message = "dev.johnrinehart.cloudflareDdns.sopsFile requires mixosModules.sops.";
          }
        ];
        dev.johnrinehart.cloudflareDdns.tokenFile = config.sops.secrets.cloudflare-api-token.path;
      })
    ]
  );
}
