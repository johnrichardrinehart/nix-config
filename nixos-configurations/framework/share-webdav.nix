{
  config,
  lib,
  pkgs,
  ...
}:
let
  primaryUser = config.dev.johnrinehart.users.primary;
  primaryGroup = config.users.users.${primaryUser}.group;
  mountPoint = "${config.users.users.${primaryUser}.home}/share";
  rcloneConfig = "/run/rclone-share/rclone.conf";
  webdavUrl = "https://share.johnrinehart.dev/remote.php/dav/files/john/";

  mountShare = pkgs.writeShellScript "mount-share-webdav" ''
    set -euo pipefail
    umask 0077

    obscured_password="$(${lib.getExe pkgs.rclone} obscure - < "$CREDENTIALS_DIRECTORY/password")"
    {
      printf '[share]\n'
      printf 'type = webdav\n'
      printf 'url = %s\n' ${lib.escapeShellArg webdavUrl}
      printf 'vendor = nextcloud\n'
      printf 'user = john\n'
      printf 'pass = %s\n' "$obscured_password"
    } > ${lib.escapeShellArg rcloneConfig}

    exec ${lib.getExe pkgs.rclone} mount share: ${lib.escapeShellArg mountPoint} \
      --config ${lib.escapeShellArg rcloneConfig} \
      --cache-dir /var/cache/rclone-share \
      --vfs-cache-mode writes \
      --vfs-cache-max-size 4Gi \
      --vfs-cache-min-free-space 8Gi \
      --vfs-cache-max-age 24h \
      --vfs-write-back 5s \
      --dir-cache-time 5m \
      --attr-timeout 1s \
      --dir-perms 0700 \
      --file-perms 0600 \
      --umask 0077 \
      --log-level INFO
  '';
in
{
  sops.secrets.share-webdav-password = {
    sopsFile = ../../secrets/share-webdav.yaml;
    key = "app-password";
    mode = "0400";
    restartUnits = [ "rclone-share.service" ];
  };

  systemd.tmpfiles.rules = [
    "d ${mountPoint} 0700 ${primaryUser} ${primaryGroup} -"
  ];

  systemd.services.rclone-share = {
    description = "Mount share.johnrinehart.dev over WebDAV";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    environment.PATH = lib.mkForce "/run/wrappers/bin:${lib.makeBinPath [ pkgs.fuse3 ]}";

    serviceConfig = {
      Type = "notify";
      User = primaryUser;
      Group = primaryGroup;
      ExecStart = mountShare;
      ExecStop = "/run/wrappers/bin/fusermount3 -u ${mountPoint}";
      RuntimeDirectory = "rclone-share";
      RuntimeDirectoryMode = "0700";
      CacheDirectory = "rclone-share";
      CacheDirectoryMode = "0700";
      LoadCredential = "password:${config.sops.secrets.share-webdav-password.path}";
      Restart = "on-failure";
      RestartSec = "10s";
      TimeoutStopSec = "30s";
      UMask = "0077";
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
    };
  };

  environment.systemPackages = [ pkgs.rclone ];
}
