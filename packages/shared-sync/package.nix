# `shared-sync`: ~/shared on the Mac and on the guest (or any machines that
# run it) is a plain local directory, kept in step with one encrypted
# directory in a Proton Drive.
#
#   shared-sync            run the sync daemon in the foreground (the launchd
#                          agent on the Mac, the systemd user unit on Linux)
#   shared-sync ARGS...    run `rclone ARGS...` with the same two remotes, e.g.
#                          `shared-sync lsf shared:` or `shared-sync check ~/shared shared:`
#
# Remotes: `proton` (the Proton Drive account) and `shared` (crypt over
# proton:${protonDir}). File data is XSalsa20-Poly1305 and names AES-256-EME
# under DIR_SHARED_RCLONE_PASSWORD, so Proton holds only rclone crypt
# ciphertext on top of its own encryption.
#
# The daemon runs `rclone bisync ~/shared shared:` a few seconds after each
# local change (FSEvents through fswatch on the Mac, inotify on Linux), and
# 30 s after each run to fetch the other machines' changes: Proton Drive has
# no change feed that rclone reads. A run takes a few seconds for a few dozen
# files, so a change reaches Proton about 10 s after it is made and another
# machine within about 45 s. When two machines change one file, the later
# upload usually wins; the other machine keeps its version in replaced/ (or,
# when one run sees both changes, beside the file as `<name>.conflict1`).
#
# Credentials come from secretspec once per daemon start: the `shared-sync`
# scope of ~/secretspec.toml, so the daemon receives only these four keys.
# The remotes are defined by RCLONE_CONFIG_* variables. The only file is
# ~/.local/state/shared-sync/rclone.conf, where rclone keeps the Proton session
# tokens it refreshes, so a run does not log in again.
{
  lib,
  pkgs,
  # secretspec executable. On the Mac this is the signed copy whose signature
  # the Keychain item for the database master password trusts.
  secretspec,
}:
let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;

  # Directory in the root of the Proton Drive that holds the ciphertext.
  protonDir = "shared-rclone-crypt";

  # Pull interval, and the quiet time after a local change before a push.
  pollSeconds = 30;
  settleSeconds = 3;

  # The `shared-sync` scope in ~/secretspec.toml must list exactly these.
  keys = [
    "PROTON_USERNAME"
    "PROTON_PASSWORD"
    "PROTON_TOTP_SECRET"
    "DIR_SHARED_RCLONE_PASSWORD"
  ];

  # One line on stdout per batch of changes under "$dir".
  watch =
    if isDarwin then
      ''fswatch --recursive --one-per-batch --latency 1 --exclude '/\.DS_Store$' "$dir"''
    else
      ''inotifywait --monitor --recursive --quiet --event close_write,create,delete,move,attrib --format . "$dir"'';

  # Runs inside `secretspec run`, with the four keys in its environment.
  withRemotes = pkgs.writeShellApplication {
    name = "shared-sync-rclone";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.openssl
      pkgs.rclone
      (if isDarwin then pkgs.fswatch else pkgs.inotify-tools)
    ];
    text = ''
      # Private: rclone.conf holds the Proton session tokens, and replaced/
      # copies of the synced files.
      state=$HOME/.local/state/shared-sync
      mkdir -p "$state"
      chmod 700 "$state"

      # `rclone obscure` (fs/config/obscure in rclone: AES-256-CTR under a key
      # published in the source, base64url of IV and ciphertext), but with a
      # zero IV instead of a random one. Remotes defined in the environment
      # get a hash of their option values in their name, `shared{hash}:`, and
      # rclone keys its caches by that name; a random IV would change it on
      # every start. Obscuring hides nothing, so a fixed IV costs nothing.
      # `rclone reveal` reads both.
      obscure() {
        {
          head -c 16 /dev/zero
          printf '%s' "$1" | openssl enc -aes-256-ctr -nosalt \
            -K 9c935b48730a554d6bfd7c63c886a92bd390198eb8128afbf4de162b8b95f638 \
            -iv 00000000000000000000000000000000
        } | basenc --base64url -w0 | tr -d =
      }

      export RCLONE_CONFIG=$state/rclone.conf
      export RCLONE_CACHE_DIR=$HOME/.cache/shared-sync
      export RCLONE_CONFIG_PROTON_TYPE=protondrive
      export RCLONE_CONFIG_PROTON_USERNAME=$PROTON_USERNAME
      RCLONE_CONFIG_PROTON_PASSWORD=$(obscure "$PROTON_PASSWORD")
      # KeePassXC shows the seed in groups of four; rclone wants it whole.
      RCLONE_CONFIG_PROTON_OTP_SECRET_KEY=$(obscure "''${PROTON_TOTP_SECRET// /}")
      export RCLONE_CONFIG_PROTON_PASSWORD RCLONE_CONFIG_PROTON_OTP_SECRET_KEY
      # The backend's link cache stays on (the default): it lives for one
      # rclone run, so it never holds the other machine's old state, and
      # without it a listing costs a few API calls per file.
      # An upload cut off half way leaves a draft that blocks the next one.
      export RCLONE_CONFIG_PROTON_REPLACE_EXISTING_DRAFT=true
      export RCLONE_CONFIG_SHARED_TYPE=crypt
      export RCLONE_CONFIG_SHARED_REMOTE=proton:${protonDir}
      RCLONE_CONFIG_SHARED_PASSWORD=$(obscure "$DIR_SHARED_RCLONE_PASSWORD")
      export RCLONE_CONFIG_SHARED_PASSWORD
      unset PROTON_USERNAME PROTON_PASSWORD PROTON_TOTP_SECRET DIR_SHARED_RCLONE_PASSWORD

      if (( $# )); then
        exec rclone "$@"
      fi

      dir=$HOME/shared
      work=$state/bisync
      # Local files that a sync deletes or overwrites, kept for 30 days.
      # Remote ones go to the Proton Drive trash.
      backup=$state/replaced
      mkdir -p "$dir" "$work" "$backup"

      sync_once() {
        local first=()
        # bisync keeps a listing of each side after a good run. Without one
        # (first run, or a run that failed badly) it needs --resync, which
        # copies each side's missing and newer files to the other and deletes
        # nothing.
        if [[ -z $(find "$work" -name '*.path1.lst' -print -quit) ]]; then
          echo "no bisync listings; resyncing"
          first=(--resync --resync-mode newer)
          # bisync does not create a missing root on either side.
          if ! rclone mkdir shared:; then
            echo "cannot create the directory on Proton Drive; trying again later" >&2
            return 0
          fi
        fi
        # --force: a deletion of most files is still a deletion the user
        # made; the replaced copies are in $backup and the Proton trash.
        if rclone bisync "$dir" shared: "''${first[@]}" \
          --workdir "$work" \
          --backup-dir1 "$backup" \
          --create-empty-src-dirs \
          --compare size,modtime \
          --conflict-resolve newer \
          --conflict-loser num \
          --resilient \
          --recover \
          --force \
          --max-lock 2m \
          --exclude .DS_Store; then
          touch "$state/last-sync"
        else
          echo "bisync failed; trying again at the next change or in ${toString pollSeconds} s" >&2
        fi
        find "$backup" -mindepth 1 -mtime +30 -delete
      }

      # A run that was killed outright (power off, SIGKILL, the VM stopped
      # with the Mac) leaves its lock file, and bisync then refuses to run
      # until --max-lock expires. This daemon is the only bisync of these
      # paths, so a lock that exists when it starts is stale. --recover then
      # continues from the listings of the last complete run.
      rm -f "$work"/*.lck
      sync_once
      while :; do
        if read -r -t ${toString pollSeconds} _; then
          # Wait until the changes stop.
          while read -r -t ${toString settleSeconds} _; do :; done
        elif (( $? <= 128 )); then
          echo "the file watcher stopped" >&2
          exit 1
        fi
        sync_once
      done < <(${watch})
    '';
  };
in
pkgs.writeShellApplication {
  name = "shared-sync";
  text = ''
    if (( $# )); then
      what="run rclone $1 on the ~/shared Proton Drive remotes"
    else
      what="sync ~/shared with the Proton Drive"
    fi
    exec ${secretspec} run \
      --file "$HOME/secretspec.toml" \
      --scope shared-sync \
      --reason "shared-sync: $what" \
      --caller shared-sync \
      --caller-operation "$what" \
      --caller-resource ${lib.concatStringsSep "," keys} \
      -- ${lib.getExe withRemotes} "$@"
  '';
}
