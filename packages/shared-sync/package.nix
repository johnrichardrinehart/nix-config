# `shared-sync`: ~/shared on the Mac and on the guest (or any machines that
# run it) is a plain local directory, kept in step with one encrypted
# directory in a Proton Drive. Each entry of `plainDirs` (for example
# `keepass`) is kept in step the same way with the directory of the same name
# in the root of the Proton Drive, without rclone crypt.
#
#   shared-sync            run the sync daemon in the foreground (the launchd
#                          agent on the Mac, the systemd user unit on Linux)
#   shared-sync ARGS...    run `rclone ARGS...` with the same two remotes, e.g.
#                          `shared-sync lsf shared:` or `shared-sync check ~/shared shared:`
#
# Remotes: `proton` (the Proton Drive account) and `shared` (crypt over
# proton:${protonDir}). File data is XSalsa20-Poly1305 and names AES-256-EME
# under DIR_SHARED_RCLONE_PASSWORD, so Proton holds only rclone crypt
# ciphertext on top of its own encryption. A plain directory syncs with
# `proton:<dir>` directly: use it for files that have their own encryption,
# such as a KeePassXC database. The Proton Drive apps can then download them,
# which a new machine needs when the credentials of this daemon are in them.
#
# The daemon runs `rclone bisync` for each directory a few seconds after each
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
  # Directories, relative to the home directory, that sync without rclone
  # crypt with the directory of the same name in the root of the Proton Drive.
  plainDirs ? [ ],
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

  checkPlainDir =
    dir:
    lib.assertMsg
      (
        builtins.match "[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*" dir != null
        && !(lib.elem ".." (lib.splitString "/" dir))
        && !(lib.elem dir [
          "shared"
          protonDir
        ])
      )
      "shared-sync: plainDirs entry `${dir}` must be a relative path other than `shared` and `${protonDir}`";

  # One entry for each synced directory. `work` (bisync listings) and `backup`
  # (replaced local files) are in the state directory; only plain
  # directories add a suffix to these names. `private` directories and the
  # files that a sync writes into them are for this user only.
  pairs = [
    {
      dir = "shared";
      remote = "shared:";
      work = "bisync";
      backup = "replaced";
      private = false;
    }
  ]
  ++ map (
    dir:
    assert checkPlainDir dir;
    let
      slug = lib.replaceStrings [ "/" ] [ "-" ] dir;
    in
    {
      inherit dir;
      remote = "proton:${dir}";
      work = "bisync-${slug}";
      backup = "replaced-${slug}";
      private = true;
    }
  ) plainDirs;

  bashArray = attr: lib.escapeShellArgs (map (pair: toString pair.${attr}) pairs);
  bashBools = attr: lib.concatMapStringsSep " " (pair: if pair.${attr} then "1" else "0") pairs;

  dirList = lib.concatMapStringsSep " and " (pair: "~/${pair.dir}") pairs;

  # One line on stdout per batch of changes under the directories in "$dirs".
  watch =
    if isDarwin then
      ''fswatch --recursive --one-per-batch --latency 1 --exclude '/\.DS_Store$' "''${dirs[@]}"''
    else
      ''inotifywait --monitor --recursive --quiet --event close_write,create,delete,move,attrib --format . "''${dirs[@]}"'';

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

      # The synced directories (see `pairs` in packages/shared-sync).
      # Local files that a sync deletes or overwrites stay in the backup
      # directory for 30 days. Remote ones go to the Proton Drive trash.
      dirs=() remotes=() works=() backups=()
      for d in ${bashArray "dir"}; do dirs+=("$HOME/$d"); done
      remotes=(${bashArray "remote"})
      for w in ${bashArray "work"}; do works+=("$state/$w"); done
      for b in ${bashArray "backup"}; do backups+=("$state/$b"); done
      privates=(${bashBools "private"})

      for i in "''${!dirs[@]}"; do
        mkdir -p "''${dirs[i]}" "''${works[i]}" "''${backups[i]}"
        if (( privates[i] )); then
          chmod 700 "''${dirs[i]}"
        fi
      done

      # Returns non-zero when the sync failed.
      sync_pair() {
        local dir=$1 remote=$2 work=$3 backup=$4 private=$5
        # A directory that is a mount point has its data on another
        # machine, for example the guest's NFS mount of the Mac's
        # ~/keepass. That machine syncs it; two syncs of one set of files
        # would fight.
        if [[ $(stat -c %d "$dir") != "$(stat -c %d "$dir/..")" ]]; then
          echo "$dir is a mount point; the machine that has its data syncs it"
          return 0
        fi
        local first=()
        # bisync keeps a listing of each side after a good run. Without one
        # (first run, or a run that failed badly) it needs --resync, which
        # copies each side's missing and newer files to the other and deletes
        # nothing.
        if [[ -z $(find "$work" -name '*.path1.lst' -print -quit) ]]; then
          echo "$dir: no bisync listings; resyncing"
          first=(--resync --resync-mode newer)
          # bisync does not create a missing root on either side.
          if ! rclone mkdir "$remote"; then
            echo "cannot create $remote on Proton Drive; trying again later" >&2
            return 1
          fi
        fi
        # Files that a sync writes into a private directory get mode 0600.
        local mask
        mask=$(umask)
        if (( private )); then
          mask=077
        fi
        # --force: a deletion of most files is still a deletion the user
        # made; the replaced copies are in $backup and the Proton trash.
        if ! (
          umask "$mask"
          rclone bisync "$dir" "$remote" "''${first[@]}" \
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
            --exclude .DS_Store
        ); then
          echo "$dir: bisync failed; trying again at the next change or in ${toString pollSeconds} s" >&2
          return 1
        fi
      }

      sync_once() {
        local i ok=1
        for i in "''${!dirs[@]}"; do
          sync_pair "''${dirs[i]}" "''${remotes[i]}" "''${works[i]}" "''${backups[i]}" "''${privates[i]}" || ok=0
          find "''${backups[i]}" -mindepth 1 -mtime +30 -delete
        done
        if (( ok )); then
          touch "$state/last-sync"
        fi
      }

      # A run that was killed outright (power off, SIGKILL, the VM stopped
      # with the Mac) leaves its lock file, and bisync then refuses to run
      # until --max-lock expires. This daemon is the only bisync of these
      # paths, so a lock that exists when it starts is stale. --recover then
      # continues from the listings of the last complete run.
      for w in "''${works[@]}"; do
        rm -f "$w"/*.lck
      done
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
      what="run rclone $1 on the shared-sync Proton Drive remotes"
    else
      what="sync ${dirList} with the Proton Drive"
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
