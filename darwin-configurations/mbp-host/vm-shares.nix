# Directories shared between this Mac and the mbp-apple-silicon guest, in
# both directions, over NFSv3.
#
# Each share's data lives on one side and is mounted on the other:
#
#   source = "guest"  the guest exports its own directory and the launcher
#                     mounts it on this Mac (vm-shares.service in the guest).
#   source = "host"   this Mac exports its own directory and the guest mounts
#                     it (vm-host-shares.service in the guest).
#
# The table becomes ~/guest-vm-fs-mappings.json, which the launcher reads at
# every start and forwards to the guest in its share manifest. For source =
# "host" shares this module also runs the Mac's nfsd from its own launchd job,
# reading an exports file under /var/db rather than /etc/exports: Some system
# checks treat an /etc/exports with contents as an NFS server to strip out, and
# it disables the Apple nfsd job it finds running. The /etc/nfs.conf settings
# below are rewritten on every activation. The guest reaches nfsd through a
# relay the launcher runs, which closes each connection properly when the guest
# closes it; macOS nfsd does not.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.dev.johnrinehart.mbp-host.vmShares;
  user = config.system.primaryUser;

  hostShares = lib.filter (share: share.source == "host") cfg;

  # nfsd reads its exports from the path in the `-F` argument (/etc/exports
  # only when the argument is absent; nfs.conf has no setting for it). The file
  # lives under /var/db, outside /etc, where some checks looks only for
  # /etc/exports; it is a plain file because the daemon is sandboxed and a link
  # into the store is not something to depend on.
  exportsFile = "/var/db/dev.johnrinehart.vm-shares.exports";

  # The guest mounts through QEMU's user-mode network, which delivers its
  # connections to this Mac's loopback from unprivileged ports. The mountd
  # port is pinned so the guest can name it rather than ask the portmapper;
  # packages/mbp-apple-silicon-qemu-vm.nix reads the live value from rpcinfo
  # regardless.
  mountdPort = 20048;
  nfsConf = ''
    # Managed by nixosConfigurations darwin-configurations/mbp-host/vm-shares.nix.
    nfs.server.require_resv_port = 0
    nfs.server.mount.require_resv_port = 0
    nfs.server.mount.port = ${toString mountdPort}
  '';
in
{
  options.dev.johnrinehart.mbp-host.vmShares = mkOption {
    description = "Directories shared with the mbp-apple-silicon guest over NFS.";
    default = [ ];
    type = types.listOf (
      types.submodule {
        options = {
          host = mkOption {
            type = types.strMatching "/[^[:space:]]*";
            description = "Absolute path on this Mac: mount point, or exported directory.";
          };
          guest = mkOption {
            type = types.strMatching "/[^[:space:]]*";
            description = "Absolute path in the guest: exported directory, or mount point.";
          };
          mode = mkOption {
            type = types.enum [
              "rw"
              "ro"
            ];
            default = "rw";
          };
          source = mkOption {
            type = types.enum [
              "guest"
              "host"
            ];
            default = "guest";
            description = "Which side the data lives on and is exported from.";
          };
        };
      }
    );
  };

  config = {
    home-manager.users.${user}.home.file."guest-vm-fs-mappings.json".text = builtins.toJSON {
      shares = map (share: {
        inherit (share)
          host
          guest
          mode
          source
          ;
        transport = "nfs";
      }) cfg;
    };

    dev.johnrinehart.provisionMac.summary.vm-shares =
      "the guest mounts this Mac's host shares through nfsd (${config.launchd.labelPrefix}.vm-shares-nfsd, exports in ${exportsFile}, not /etc/exports; pgrep nfsd sees the daemon)";

    launchd.daemons.vm-shares-nfsd = lib.mkIf (hostShares != [ ]) {
      serviceConfig = {
        ProgramArguments = [
          "/sbin/nfsd"
          "-F"
          exportsFile
        ];
        KeepAlive.PathState = {
          ${exportsFile} = true;
        };
        RunAtLoad = true;
      };
    };

    system.activationScripts.postActivation.text = lib.mkAfter (
      if hostShares == [ ] then
        ''
          if [[ -s ${exportsFile} ]]; then
            echo "no VM host shares; stopping nfsd" >&2
            launchctl bootout system/${config.launchd.labelPrefix}.vm-shares-nfsd 2>/dev/null || true
            # A KeepAlive restart could race the removal; wait until the
            # daemon is actually gone before taking its exports file away.
            down=0
            for (( i=0; i<10; i++ )); do
              if [[ $(/sbin/nfsd status 2>/dev/null) != *'is running'* ]]; then
                down=1
                break
              fi
              sleep 1
            done
            (( down )) || echo "warning: nfsd still running; its exports file stays" >&2
            (( down )) && rm -f ${exportsFile}
          fi
          if [[ -e /etc/exports ]]; then
            echo "removing leftover /etc/exports" >&2
            rm -f /etc/exports
          fi
        ''
      else
        ''
          echo "setting up NFS exports for the VM guest..." >&2
          uid=$(id -u ${lib.escapeShellArg user})
          gid=$(id -g ${lib.escapeShellArg user})
          ${lib.concatMapStrings (share: ''
            if [[ ! -d ${lib.escapeShellArg share.host} ]]; then
              install -d -m 0700 -o "$uid" -g "$gid" ${lib.escapeShellArg share.host}
            fi
          '') hostShares}

          # Every request is served as the primary user whoever the guest says
          # it is, and only the loopback (where QEMU delivers the guest) may
          # mount.
          exports=$(mktemp)
          {
            echo '# Managed by nixosConfigurations darwin-configurations/mbp-host/vm-shares.nix.'
            ${lib.concatMapStrings (share: ''
              printf '%s -mapall=%s:%s%s localhost\n' ${lib.escapeShellArg share.host} "$uid" "$gid" ${
                if share.mode == "ro" then "' -ro'" else "''"
              }
            '') hostShares}
          } >"$exports"

          changed=0
          if ! cmp -s "$exports" ${exportsFile}; then
            install -m 0644 "$exports" ${exportsFile}
            changed=1
          fi
          rm -f "$exports"
          if ! cmp -s <(printf '%s' ${lib.escapeShellArg nfsConf}) /etc/nfs.conf; then
            printf '%s' ${lib.escapeShellArg nfsConf} >/etc/nfs.conf
            changed=1
          fi
          # An /etc/exports left by an older switch would start the Apple nfsd
          # job; take it away. One /var/run/nfsd.pid exists for every
          # /sbin/nfsd: an instance left over would block ours at the pidfile
          # and keep serving whatever it read last. Stop one only when it is
          # running; `nfsd stop` also tells the kernel to drop all exports, and
          # ours are re-exported by this same activation.
          if [[ -e /etc/exports ]]; then
            rm -f /etc/exports
            changed=1
          fi
          if /sbin/nfsd status 2>/dev/null | grep -q 'is running'; then
            /sbin/nfsd stop >/dev/null 2>&1 || true
          fi

          job=${config.launchd.labelPrefix}.vm-shares-nfsd
          if ! launchctl print system/$job >/dev/null 2>&1; then
            launchctl bootstrap system /Library/LaunchDaemons/$job.plist
          elif (( changed )); then
            launchctl kickstart -k system/$job &
          fi
          # Wait, bounded, for the daemon to be up; a spawn that never
          # succeeds (a launch-constraint refusal, say) must fail this
          # activation, not hang it.
          up=0
          for (( i=0; i<10; i++ )); do
            if [[ $(/sbin/nfsd status 2>/dev/null) == *'is running'* ]]; then
              up=1
              break
            fi
            sleep 1
          done
          if (( ! up )); then
            echo "error: $job did not start; run: launchctl print system/$job" >&2
            exit 1
          fi
          # checkexports also asks whether the nfsd daemon's sandbox could
          # read each path, and says no for directories in a home folder. The
          # kernel NFS server does the serving and is not bound by that, so
          # those lines are only warnings; any other complaint is fatal.
          if ! report=$(/sbin/nfsd -F ${exportsFile} checkexports 2>&1); then
            if grep -v -e 'sandbox_check failed' -e "can't verify exports permissions" <<<"$report" | grep -q .; then
              printf '%s\n' "$report" >&2
              echo "error: nfsd rejected ${exportsFile}" >&2
              exit 1
            fi
            printf 'warning (harmless): %s\n' "$report" >&2
          fi
        ''
    );
  };
}
