{ config, pkgs, ... }:
let
  primaryUser = config.dev.johnrinehart.users.primary;
  passwordPath = config.sops.secrets.git-send-email-password.path;

  # git send-email asks the credential helper for the SMTP password.
  # Answer only "get" requests, so git never tries to store the password.
  # Google shows app passwords in groups of four; drop the spaces.
  credentialHelper = pkgs.writeShellScript "git-credential-gmail-smtp" ''
    [ "$1" = get ] || exit 0
    printf 'password=%s\n' "$(tr -d '[:space:]' < ${passwordPath})"
  '';
in
{
  # Gmail app password for git send-email.
  sops.secrets.git-send-email-password = {
    sopsFile = ../../secrets/framework.yaml;
    key = "git-send-email";
    owner = primaryUser;
    mode = "0400";
  };

  home-manager.users.${primaryUser}.programs.git.settings = {
    sendemail = {
      smtpServer = "smtp.gmail.com";
      smtpServerPort = 587;
      smtpEncryption = "tls";
      smtpUser = "johnrichardrinehart@gmail.com";
    };
    credential."smtp://johnrichardrinehart%40gmail.com@smtp.gmail.com:587".helper = "${
      credentialHelper
    }";
  };
}
