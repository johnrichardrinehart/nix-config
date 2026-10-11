{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.repo-manager;
  primaryUser = config.dev.johnrinehart.users.primary;
  format = pkgs.formats.json { };
  configFile = format.generate "repo-manager-config.json" cfg.settings;

  # One identity declaration feeds two consumers so that repositories
  # repo-manager manages (repository-local config it writes) and ones it does
  # not (global includeIf) resolve to the same keys:
  #   - `settings.identities`, which repo-manager applies per locator prefix, and
  #   - `programs.git.includes` with `hasconfig:remote.*.url` conditions, which
  #     Git evaluates by remote URL, so the identity follows the repository
  #     rather than its checkout location. Those also carry the fields
  #     repo-manager has no notion of (user.email, user.name).
  # Repository-local config wins over includes, so the values must agree; they
  # are derived from the same attribute here.
  #
  # Every path is `~`-relative so the same config works from the Mac and from
  # inside its guest, whose home directories differ. Git expands `~` in
  # user.signingKey itself and core.sshCommand runs through a shell.
  identities = lib.filterAttrs (_: identity: identity.enable) cfg.identities;

  # Mirrors repo-manager's inference: SSH signing keys are paths or literal
  # `key::ssh-…` values; OpenPGP key ids look like neither.
  inferSigningFormat =
    key:
    if
      lib.any (prefix: lib.hasPrefix prefix key) [
        "key::"
        "ssh-"
        "sk-ssh-"
        "sk-ecdsa-"
        "ecdsa-sha2-"
        "~/"
        "/"
        "./"
      ]
      || lib.hasSuffix ".pub" key
    then
      "ssh"
    else
      null;

  signingFormatFor =
    identity:
    if identity.signingFormat != null then
      identity.signingFormat
    else if identity.signingKey != null then
      inferSigningFormat identity.signingKey
    else
      null;

  sshCommandFor = identity: "ssh -o IdentitiesOnly=yes -i ${identity.sshIdentityFile}";

  repoManagerIdentity =
    identity:
    lib.filterAttrs (_: value: value != null) {
      "ssh-identity-file" = identity.sshIdentityFile;
      "signing-key" = identity.signingKey;
      "signing-format" = signingFormatFor identity;
    };

  gitIdentity =
    identity:
    let
      signing = identity.signingKey != null;
      signingFormat = signingFormatFor identity;
    in
    lib.filterAttrs (_: value: value != { }) {
      user = lib.filterAttrs (_: value: value != null) {
        inherit (identity) email name;
        inherit (identity) signingKey;
      };
      gpg = lib.optionalAttrs (signingFormat != null) { format = signingFormat; };
      commit = lib.optionalAttrs signing { gpgsign = true; };
      tag = lib.optionalAttrs signing { gpgsign = true; };
      core = lib.optionalAttrs (identity.sshIdentityFile != null) {
        sshCommand = sshCommandFor identity;
      };
    };

  # `hasconfig` matches with pathname semantics: `*` stops at `/`, `**/` spans
  # whole components, and a trailing `/**` matches everything inside. A remote
  # appears in one of three shapes, and the user part makes them distinct:
  #   https://authority/path        ssh://user@authority/path        user@authority:path
  # so each prefix needs one pattern per shape. An authority or an owner is
  # always followed by more path. A prefix three segments deep may name a
  # repository, which ends the URL bare or with `.git`, or a nested group on a
  # forge that has them, so from that depth the terminal forms are added to
  # the descending one. The match is case-sensitive and applies to the
  # configured URL, before any url.<base>.insteadOf rewriting.
  conditionsFor =
    prefix:
    let
      parts = lib.splitString "/" prefix;
      authority = lib.head parts;
      path = lib.concatStringsSep "/" (lib.tail parts);
      # Locators are <authority>/<owner>/<repo>, but forges with nested groups
      # go deeper, so three segments may be a repository or a group.
      mayNameRepository = lib.length parts >= 3;
      tails =
        (if path == "" then [ "/**" ] else [ "/${path}/**" ])
        ++ lib.optionals mayNameRepository [
          "/${path}"
          "/${path}.git"
        ];
      heads = [
        "**/${authority}"
        "**/*@${authority}"
        "*@${authority}:"
      ];
      # The scp form has no slash between authority and path, and a bare `**`
      # after the colon does not span components the way `/**` does, so the
      # authority-wide tail needs one explicit path component first.
      join =
        head: tail:
        if !lib.hasSuffix ":" head then
          head + tail
        else if tail == "/**" then
          head + "*/**"
        else
          head + lib.removePrefix "/" tail;
    in
    map (pattern: "hasconfig:remote.*.url:${pattern}") (
      lib.concatMap (head: map (join head) tails) heads
    );

  # Git applies includes in order and later values win, so a repository prefix
  # must follow its owner, which must follow its authority: sort by depth.
  orderedPrefixes = lib.sort (
    a: b: lib.length (lib.splitString "/" a) < lib.length (lib.splitString "/" b)
  ) (lib.attrNames identities);

  gitIncludes = lib.concatMap (
    prefix:
    let
      contents = gitIdentity identities.${prefix};
    in
    lib.optionals (contents != { }) (
      map (condition: { inherit condition contents; }) (conditionsFor prefix)
    )
  ) orderedPrefixes;

  repoManagerIdentities = lib.filterAttrs (_: value: value != { }) (
    lib.mapAttrs (_: repoManagerIdentity) identities
  );
in
{
  options.dev.johnrinehart.repo-manager = {
    enable = lib.mkEnableOption "repo-manager configuration";

    package = lib.mkPackageOption pkgs.dev.johnrinehart "repo-manager" { };

    settings = lib.mkOption {
      inherit (format) type;
      default = { };
      description = ''
        repo-manager JSON configuration written to
        ~/.config/repo-manager/config.json for the primary user. Each default
        key can be overridden on its own; `identities` is generated from the
        `identities` option and should not be set here.
      '';
    };

    identities = lib.mkOption {
      default = { };
      description = ''
        Git identities keyed by locator prefix: `<authority>`,
        `<authority>/<owner>`, `<authority>/<owner>/<repo>`, or any deeper
        prefix. More specific prefixes override less specific ones field by
        field, in repo-manager and in the generated Git includes alike.
        Owner and repository segments are matched case-sensitively against
        remote URLs by Git, so list every spelling remotes actually use.
      '';
      example = lib.literalExpression ''
        {
          "github.com".sshIdentityFile = "~/.ssh/id_ed25519_personal";
          "github.com/work-org" = {
            sshIdentityFile = "~/.ssh/id_ed25519_work";
            signingKey = "~/.ssh/id_ed25519_work.pub";
            email = "me@work.example";
          };
        }
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether this prefix contributes an identity.";
            };
            sshIdentityFile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Key passed to `ssh -o IdentitiesOnly=yes -i`, as
                core.sshCommand in managed repositories and in the matching
                Git include. A `.pub` path is enough when the private key is
                held by an SSH agent.
              '';
            };
            signingKey = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                user.signingKey. Also enables commit.gpgsign and tag.gpgsign.
              '';
            };
            signingFormat = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.enum [
                  "openpgp"
                  "ssh"
                  "x509"
                ]
              );
              default = null;
              description = ''
                gpg.format. Defaults to `ssh` when signingKey looks like an SSH
                key (a path, `.pub`, or `key::ssh-…`), otherwise Git's default.
              '';
            };
            email = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "user.email for the Git include; repo-manager does not manage it.";
            };
            name = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "user.name for the Git include; repo-manager does not manage it.";
            };
          };
        }
      );
    };

    daemon = {
      enable = lib.mkEnableOption "the repo-manager user daemon";
      package = lib.mkPackageOption pkgs.dev.johnrinehart "repod" { };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
    ]
    ++ lib.optional cfg.daemon.enable cfg.daemon.package;

    dev.johnrinehart.repo-manager.settings =
      lib.mapAttrs (_: lib.mkDefault) {
        cache_root = "/home/${primaryUser}/.cache/repo-manager";
        auto_create_remote = false;
        config_version = 1;
        clone_start_ttl_minutes = 60;
        detect_related = true;
        root = "/home/${primaryUser}/code";
        rpc_rate_limit_per_second = 1;
        state = "/home/${primaryUser}/.local/state/repo-manager/repos.sqlite";
      }
      // lib.optionalAttrs (repoManagerIdentities != { }) { identities = repoManagerIdentities; };

    home-manager.users.${primaryUser} = {
      xdg.configFile."repo-manager/config.json".source = configFile;

      programs.git.includes = gitIncludes;

      # Git stores repo-manager fork branches under custom refs, so Oh My Zsh
      # cannot show their short names. Add the display fix only with Oh My Zsh.
      programs.zsh.initContent =
        lib.mkIf config.home-manager.users.${primaryUser}.programs.zsh.oh-my-zsh.enable
          (
            lib.mkAfter ''
              # Preserve glg's git log --stat behavior and label ref kinds
              # so namespaces and remotes remain distinct.
              unalias glg 2>/dev/null || true
              glg() {
                local color=never
                local branch_color=""
                local namespace_color=""
                local remote_color=""
                local -a pager
                if [[ -t 1 ]]; then
                  color=always
                  branch_color=$(git config --get-color color.decorate.branch 'green bold')
                  namespace_color=$(git config --get-color color.decorate.branch 'green bold')
                  remote_color=$(git config --get-color color.decorate.remoteBranch 'cyan')
                  pager=(less -R)
                else
                  pager=(cat)
                fi

                git log --stat --color="$color" --decorate=full \
                  --decorate-refs='refs/*' "$@" |
                  sed -E \
                    -e "s#refs/namespaces/([^/]+)/refs/heads/#''${namespace_color}namespace/\\1/#g" \
                    -e "s#refs/repo-manager/[^[:space:],)]*/remotes/([^/]+)/#''${remote_color}remote/fork/\\1/#g" \
                    -e "s#refs/repo-manager/[^[:space:],)]*/heads/#''${namespace_color}namespace/fork/#g" \
                    -e "s#refs/remotes/([^/]+)/#''${remote_color}remote/\\1/#g" \
                    -e "s#refs/heads/#''${branch_color}#g" \
                    -e "s#refs/tmp/#''${namespace_color}namespace/tmp/#g" |
                  "''${pager[@]}"
              }
            ''
          );

      systemd.user.services.repod = lib.mkIf cfg.daemon.enable {
        Unit = {
          Description = "repo-manager RPC daemon";
        };

        Service = {
          ExecStart = lib.getExe cfg.daemon.package;
          Restart = "on-failure";
        };

        Install.WantedBy = [ "default.target" ];
      };
    };
  };
}
