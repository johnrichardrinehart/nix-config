{
  config,
  lib,
  osConfig,
  pkgs,
  ...
}:
let
  terminalEmulator = osConfig.dev.johnrinehart.users.terminalEmulator.package;
  kittyIntegrationEnabled =
    osConfig.dev.johnrinehart.users.terminalEmulator.integrations.kitty.enable;
  stalonetrayrc = pkgs.writeText "stalonetrayrc" ''
    background "#3B4252"
    geometry "3x1+1150-0"
    icon_size "24"
    sticky true
    transparent true
    window_strut bottom
  '';
  agentToolsGitignoreEntries = lib.optionalString osConfig.dev.johnrinehart.agentTools.enable ''
    .codex/
    .codex
    .omx/
    .omp/
  '';
  ompRuntimeConfigPath = "${config.home.homeDirectory}/.omp/agent/runtime-config.yml";
  emptyOmpRuntimeConfig = pkgs.writeText "omp-runtime-config.yml" ''
    {}
  '';
  ompMcpConfigPath = "${config.home.homeDirectory}/.omp/agent/mcp.json";
  defaultOmpMcpConfig = pkgs.writeText "omp-mcp.json" (
    builtins.toJSON {
      mcpServers.context-mode = {
        type = "stdio";
        command = "context-mode";
      };
    }
  );
  agentDeckConfig = ''
    # Agent Deck Configuration
    # Managed by Home Manager

    default_tool = "my-codex"
    theme = "dark"

    [tools.my-codex]
    command = "${lib.getExe pkgs.dev.johnrinehart.codex-cli-nix}"
    compatible_with = "codex"

    [tools.my-claude]
    command = "${lib.getExe pkgs.dev.johnrinehart.claude-code-nix}"
    compatible_with = "claude"

    # OMX currently runs Codex inside the existing tmux pane and may also mutate the
    # outer tmux window (for example by creating a HUD split and enforcing tmux
    # ownership checks). These wrappers normalize agent-deck's appended
    # `resume <session-id>` shape into the OMX argv order that preserves the
    # intended flags on resumed sessions.
    [tools.omx-high]
    command = "${lib.getExe' pkgs.dev.johnrinehart.omx-agent-tools "omx-high"}"
    compatible_with = "codex"

    [tools.omx-high-sandboxed-ralph]
    command = "${lib.getExe' pkgs.dev.johnrinehart.omx-agent-tools "omx-high-sandboxed-ralph"}"
    compatible_with = "codex"

    # agent-deck ships `omp` as a built-in tool and rejects any [tools.omp]
    # entry that shadows it. Its session handling (--continue, --session-dir,
    # fork, per-session --model) is keyed on the literal tool name "omp", so a
    # custom [tools.my-omp] wrapper with compatible_with = "omp" would only
    # inherit busy/prompt patterns. Override the built-in's command instead so
    # agent-deck launches the same Nix-provided omp as the shell does.
    [omp]
    command = "${lib.getExe osConfig.dev.johnrinehart.agentTools.omp.package}"

    [worktree]
    default_location = "sibling"
    auto_cleanup = true
    path_template = "{repo-root}/{branch-escaped}"

    [global_search]
    recent_days = 90

    [instances]
    allow_multiple = true
  '';
  # The git segment's ignore_status is the one per-host knob in the prompt
  # configuration. Hosts that leave it empty get the checked-in file unchanged,
  # so their store path does not move.
  ohMyPoshIgnoreStatus = osConfig.dev.johnrinehart.programs.oh-my-posh.git.ignoreStatus;
  ohMyPoshConfig =
    if ohMyPoshIgnoreStatus == [ ] then
      ./oh-my-posh.json
    else
      let
        base = builtins.fromJSON (builtins.readFile ./oh-my-posh.json);
        patchSegment =
          segment:
          if segment.type == "git" then
            segment
            // {
              options = (segment.options or { }) // {
                ignore_status = ohMyPoshIgnoreStatus;
              };
            }
          else
            segment;
        patchBlock = block: block // { segments = map patchSegment block.segments; };
      in
      pkgs.writeText "oh-my-posh.json" (
        builtins.toJSON (base // { blocks = map patchBlock base.blocks; })
      );
in
{
  imports = [
    #    ../wm/xmonad
    ./options.nix
  ];

  config = {
    # only use flameshot with Xorg
    services.flameshot.enable = osConfig.services.xserver.enable;

    services.gpg-agent = {
      enable = true;
    };

    services.network-manager-applet.enable = true;

    services.polybar =
      let
        bars = builtins.readFile ./polybar/bars.ini;
        colors = builtins.readFile ./polybar/colors.ini;
        modules = builtins.readFile ./polybar/modules.ini;
        user_modules = builtins.readFile ./polybar/user_modules.ini;
        module_xmonad = ''
          [module/xmonad]
          type = custom/script
          exec = ${pkgs.xmonad-log}/bin/xmonad-log

          tail = true
        '';
        module_pt = ''
          [module/time-pt]
          type = custom/script
          exec = TZ=America/Los_Angeles ${pkgs.coreutils}/bin/date +"%a, %d %b %H:%M"
          interval = 59
        '';
        module_nyc_time = ''
          [module/time-nyc]
          type = custom/script
          exec = TZ=America/New_York ${pkgs.coreutils}/bin/date +"(ET: %H:%M)"
          interval = 59
        '';
      in
      {
        # only use polybar with Xorg
        inherit (osConfig.services.xserver) enable;
        package = pkgs.polybar.override {
          alsaSupport = true;
          pulseSupport = true;
          githubSupport = true;
        };
        config = ./polybar/config.ini;
        script = ''
          # The below script has a weird structure, mostly owing to the long
          # delay introduced by `xrandr` detecting and setting the display
          # settings (when the window manager starts up). We basically need
          # to wait a few seconds until the window manager has established 
          # which screens are on and what their resolutions are before we
          # start polybar, otherwise it starts on the first detected screen
          # and then may jump to a later-activated screen (which may have a
          # different resolution). The end result being a poylbar that is either
          # either too short or too long. 3 seconds seems to be a kind of sweet
          # spot for my hardware. However, stalonetray starts up faster than
          # polybar so we need to add an additional delay to its startup so that
          # we don't hide stalonetray behind polybar when polybar finishes
          # loading.

          startPolybar() {
             ${pkgs.coreutils}/bin/sleep 2
             ${pkgs.polybar}/bin/polybar $1
          }

          startStalonetray() {
             ${pkgs.coreutils}/bin/sleep 5
             ${pkgs.stalonetray}/bin/stalonetray --config ${stalonetrayrc}
          }

          startPolybar main &
          startStalonetray &
        '';
        extraConfig = bars + colors + modules + user_modules + module_xmonad + module_pt + module_nyc_time;
      };

    home.file = {
      ".gitignore".text = ''
        result
        .claude/
      ''
      + agentToolsGitignoreEntries;
      ".config/satty/config.toml".text = ''
        [general]
        initial-tool = "pointer"
      '';
      ".config/fuzzel/fuzzel.ini".text = ''
        [main]
        width=60

        [colors]
        background=20242df2
        text=d8dee9ff
        prompt=8fbcbbff
        input=e5e9f0ff
        match=a3be8cff
        selection=3b4252ff
        selection-text=eceff4ff
        selection-match=bfdb9dff
        border=5e81acff
      '';
      ".config/monstar/config".text = ''
        font-family = Fira Mono for Powerline
        font-weight = medium
        synthetic-italic = true
        synthetic-italic-weight = bold
        font-size = 12
        block-shade-style = kitty
        foreground = #CAD3F5
        background = #000000
        selection-foreground = #24273A
        selection-background = #F4DBD6
        cursor-color = #F4DBD6
        cursor-text = #24273A
        palette = 0=#494D64
        palette = 1=#ED8796
        palette = 2=#A6DA95
        palette = 3=#EED49F
        palette = 4=#8AADF4
        palette = 5=#F5BDE6
        palette = 6=#8BD5CA
        palette = 7=#B8C0E0
        palette = 8=#5B6078
        palette = 9=#ED8796
        palette = 10=#A6DA95
        palette = 11=#EED49F
        palette = 12=#8AADF4
        palette = 13=#F5BDE6
        palette = 14=#8BD5CA
        palette = 15=#A5ADCB
      '';
      ".config/powerline/themes/gruvbox.theme".source = ./gruvbox.theme;
      ".config/hypr/hyprlock.conf".source = ./hyprlock.conf;
      ".codex/skills/usage-status".source = ./skills/usage-status;
      ".config/hypr/hyprpaper.conf".source =
        let
          wallpaper = builtins.path {
            path = ../../static/full-moon-forest-night-dark-starry-sky-5k-8k-7952x5304-1684.jpg;
            name = "wallpaper.jpg";
          };
        in
        (pkgs.replaceVars ./hyprpaper.conf {
          inherit wallpaper;
        }).overrideAttrs
          (_: {
            checkPhase = null;
          });
    }
    // lib.optionalAttrs osConfig.dev.johnrinehart.agentTools.enable {
      ".agent-deck/config.toml".text = agentDeckConfig;
    }
    // lib.optionalAttrs osConfig.dev.johnrinehart.desktop.greetd_niri.hypridle.enable {
      ".config/hypr/hypridle.conf".source =
        let
          sshSessionLockCfg = osConfig.dev.johnrinehart.sshSessionLock;
          confirmSshActivityPackage = pkgs.dev.johnrinehart.confirm-ssh-activity-before-suspend.override {
            promptTimeoutSeconds = sshSessionLockCfg.suspendPromptTimeoutSeconds;
          };
          lockIdleSshPackage = pkgs.dev.johnrinehart.lock-idle-ssh-sessions.override {
            idleTimeoutSeconds = sshSessionLockCfg.timeoutSeconds;
            inherit (sshSessionLockCfg) terminalMultiplexer;
            tmux = pkgs.dev.johnrinehart.tmux;
          };
          onIdlePackage = pkgs.dev.johnrinehart.on-idle.override {
            idleTimeoutSeconds = config.idle.short_timeout_duration;
            idleSshActionCommand = lib.optionalString sshSessionLockCfg.enable (lib.getExe lockIdleSshPackage);
          };
          onLongIdlePackage = pkgs.dev.johnrinehart.suspend-if-no-active-ssh.override {
            confirmSshActivityCommand = lib.optionalString sshSessionLockCfg.enable (
              lib.getExe confirmSshActivityPackage
            );
          };
        in
        (pkgs.replaceVars ./hypridle.conf {
          lock_command = lib.getExe pkgs.hyprlock;
          loginctl = lib.getExe' pkgs.systemd "loginctl";
          monitor_off = "${lib.getExe pkgs.niri} msg action power-off-monitors";
          notify_send = lib.getExe' pkgs.libnotify "notify-send";
          on_idle = lib.getExe onIdlePackage;
          on_long_idle = lib.getExe onLongIdlePackage;
          on_long_resume = lib.getExe (
            pkgs.dev.johnrinehart.kill-idle-group.override {
              onIdlePackage = onLongIdlePackage;
            }
          );
          on_short_resume = lib.getExe (
            pkgs.dev.johnrinehart.kill-idle-group.override {
              inherit onIdlePackage;
            }
          );
          inherit (config.idle) short_timeout_duration;
          inherit (config.idle) medium_timeout_duration;
          inherit (config.idle) long_timeout_duration;
        }).overrideAttrs
          (_: {
            checkPhase = null;
          });
    };

    # OMP must lock and rewrite its global config file, so install a writable
    # copy. PI_CONFIG_FILES loads the runtime file afterward as a higher-priority
    # overlay. Home Manager never replaces that runtime file.
    home.activation.ompConfig = lib.mkIf osConfig.dev.johnrinehart.agentTools.omp.enable (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run mkdir -p "$HOME/.omp/agent"
        run install -m 600 ${./omp-config.yml} "$HOME/.omp/agent/config.yml"
        run install -m 600 ${./omp-keybindings.yml} "$HOME/.omp/agent/keybindings.yml"
        if [[ ! -e "${ompRuntimeConfigPath}" ]]; then
          run install -m 600 ${emptyOmpRuntimeConfig} "${ompRuntimeConfigPath}"
        fi
        if [[ -e "${ompMcpConfigPath}" ]]; then
          mcp_config_tmp="$(mktemp)"
          ${lib.getExe pkgs.jq} \
            '.mcpServers."context-mode" = {"type":"stdio","command":"context-mode"}' \
            "${ompMcpConfigPath}" > "$mcp_config_tmp"
          run install -m 600 "$mcp_config_tmp" "${ompMcpConfigPath}"
          run rm "$mcp_config_tmp"
        else
          run install -m 600 ${defaultOmpMcpConfig} "${ompMcpConfigPath}"
        fi
      ''
    );

    # oh-my-posh's `init zsh` (evaluated in the zsh init below) does not inline
    # the prompt setup; it sources a persistent cache script,
    # ~/.cache/oh-my-posh/init.<hash>.zsh, whose <hash> is derived from the shell
    # and config path, not the oh-my-posh version. That cache hard-codes the
    # absolute /nix/store path of the binary that wrote it, so after an upgrade
    # the unchanged hash means the stale cache is reused; a later
    # `nix-collect-garbage` then deletes the store path it still points at and
    # every shell — newly started ones included — fails with "no such file or
    # directory: .../oh-my-posh". Activation runs on each switch, i.e. exactly
    # when the binary path can change, so drop the cache here to force
    # regeneration against the current binary; the next shell recreates it.
    home.activation.clearOhMyPoshInitCache = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run rm -f "$HOME/.cache/oh-my-posh/"init.*.zsh
    '';

    programs.tmux =
      lib.mkIf
        (
          osConfig.dev.johnrinehart.sshSessionLock.enable
          && osConfig.dev.johnrinehart.sshSessionLock.terminalMultiplexer == "tmux"
        )
        {
          enable = true;
          package = pkgs.dev.johnrinehart.tmux;
          extraConfig =
            let
              tmuxAuthLock = pkgs.dev.johnrinehart.tmux-auth-lock;
            in
            ''
              set -g lock-command "${lib.getExe tmuxAuthLock}"
            '';
        };

    home.sessionVariables = {
      EDITOR = "vim";
      TERMINAL = lib.getExe terminalEmulator;
      TMUX_TMPDIR = lib.mkForce osConfig.dev.johnrinehart.tmux.socketDir;
    }
    // lib.optionalAttrs osConfig.dev.johnrinehart.agentTools.omp.enable {
      PI_CONFIG_FILES = ompRuntimeConfigPath;
    };

    dconf.settings = {
      "org/gnome/nautilus/preferences" = {
        default-sort-order = "mtime";
        default-sort-in-reverse-order = true;
      };
    };

    gtk = {
      enable = true;
      theme = {
        package = pkgs.adw-gtk3;
        name = "adw-gtk3-dark";
      };
      gtk3.extraConfig = {
        gtk-application-prefer-dark-theme = 1;
      };
      gtk4.extraConfig = {
        gtk-application-prefer-dark-theme = 1;
      };
      gtk4.theme = config.gtk.theme;
    };

    programs.direnv = {
      enable = true;
      nix-direnv = {
        enable = true;
        package = pkgs.nix-direnv.override {
          nix = osConfig.nix.package;
        };
      };
      config = {
        whitelist = {
          prefix = [ "/home/john/code/repos/sr.ht/fuzzybear3965/" ];
        };
      };
    };

    programs.git = {
      enable = true;
      package = pkgs.dev.johnrinehart.git-local-namespace;
      settings = {
        user = {
          name = "John Rinehart";
          email = "johnrichardrinehart@gmail.com";
        };
        init.defaultBranch = "main";
        core.editor = "vim";
        # TODO: commented for cargo-tarpaulin, remove line if nothing breaks
        url = {
          "git@github.com:" = {
            insteadOf = "https://github.com";
          };
        };
        core.excludesFile = "~/.gitignore";
        pull.rebase = true;
        # repo-manager sets this per repository as it touches them, and passes
        # it on every git call it makes; this covers `git worktree add` by hand
        # in clones it has not touched since. The managed tree is seen from
        # more than one absolute path - /Users/... on the Mac, /home/... in
        # its guest - and only a relative link resolves from both.
        worktree.useRelativePaths = true;
      };
    };

    programs.gpg.enable = true;

    home.packages = [ pkgs.kitty ];

    programs.kitty = lib.mkIf kittyIntegrationEnabled {
      enable = true;
      font.size = 12;
      font.name = "Fira Mono Medium for Powerline";
      keybindings = {
        "ctrl+alt+up" = "send_text all \\x1b[<64;10;10M";
        "ctrl+alt+down" = "send_text all \\x1b[<65;10;10M";
        # Preserve both modifiers for OMP's clear-editor binding.
        "ctrl+shift+backspace" = "send_text all \\x1b[127;6u";
      };
      extraConfig = ''
        hide_window_decorations yes
        enable_audio_bell no
        scrollback_lines 250000

        # Use -r instead of default -R so less passes all escape sequences through,
        # preventing oh-my-posh prompt garbling in scrollback.
        scrollback_pager less --raw-control-chars +INPUT_LINE_NUMBER

        # vim:ft=kitty

        ## name:     Catppuccin Kitty Macchiato
        ## author:   Catppuccin Org
        ## license:  MIT
        ## upstream: https://github.com/catppuccin/kitty/blob/main/macchiato.conf
        ## blurb:    Soothing pastel theme for the high-spirited!



        # The basic colors
        foreground              #CAD3F5
        background              #000000
        selection_foreground    #24273A
        selection_background    #F4DBD6

        # Cursor colors
        cursor                  #F4DBD6
        cursor_text_color       #24273A

        # URL underline color when hovering with mouse
        url_color               #F4DBD6

        # Kitty window border colors
        active_border_color     #B7BDF8
        inactive_border_color   #6E738D
        bell_border_color       #EED49F

        # OS Window titlebar colors
        wayland_titlebar_color system
        macos_titlebar_color system

        # Tab bar colors
        active_tab_foreground   #181926
        active_tab_background   #C6A0F6
        inactive_tab_foreground #CAD3F5
        inactive_tab_background #1E2030
        tab_bar_background      #181926

        # Colors for marks (marked text in the terminal)
        mark1_foreground #24273A
        mark1_background #B7BDF8
        mark2_foreground #24273A
        mark2_background #C6A0F6
        mark3_foreground #24273A
        mark3_background #7DC4E4

        # The 16 terminal colors

        # black
        color0 #494D64
        color8 #5B6078

        # red
        color1 #ED8796
        color9 #ED8796

        # green
        color2  #A6DA95
        color10 #A6DA95

        # yellow
        color3  #EED49F
        color11 #EED49F

        # blue
        color4  #8AADF4
        color12 #8AADF4

        # magenta
        color5  #F5BDE6
        color13 #F5BDE6

        # cyan
        color6  #8BD5CA
        color14 #8BD5CA

        # white
        color7  #B8C0E0
        color15 #A5ADCB
      '';
    };

    programs.rofi = {
      enable = true;
      extraConfig = {
        modi = "window,windowcd,run,ssh,drun,combi,keys,filebrowser";
      };
    };

    programs.vim = {
      enable = true;
      extraConfig = ''
        set autochdir
        set number
        syntax on
        filetype on

        autocmd BufNewFile,BufRead *.svelte set filetype=html

        " highlight trailing whitespace
        " https://stackoverflow.com/a/4617156/1477586
        :highlight ExtraWhitespace ctermbg=red guibg=red
        :match ExtraWhitespace /\s\+$/
      '';
      plugins =
        let
          p = pkgs.vimPlugins;
        in
        [
          p.vim-airline
          p.vim-plug
          p.julia-vim
        ];
    };

    programs.zsh = {
      enable = true;

      plugins = [
        {
          name = "zsh-nix-shell";
          file = "nix-shell.plugin.zsh";
          src = pkgs.fetchFromGitHub {
            owner = "chisui";
            repo = "zsh-nix-shell";
            rev = "v0.8.0";
            hash = "sha256-Z6EYQdasvpl1P78poj9efnnLj7QQg13Me8x1Ryyw+dM=";
          };
        }
      ];

      autosuggestion.enable = true;

      shellAliases =
        let
          fetchLatestKernelVersion =
            release_line:
            let
              kernelOrgXpath =
                release_line:
                let
                  row = release_line: if release_line == "mainline" then "1" else "2";
                in
                ''//table[@id="releases"]/tr[${row release_line}]/td[2]/strong/text()'';
              xpath = kernelOrgXpath release_line;
            in
            "curl --silent 'https://kernel.org' | xmllint -html -xpath '${xpath}' - 2>/dev/null";
        in
        {
          lt = "ls -lhrtc";
          # from https://stackoverflow.com/a/47285611
          gbbd = "git for-each-ref --sort=committerdate refs/heads/ --format='%(color: red)%(committerdate:short) %(color: cyan)%(refname:short)'";
          # latest kernel version
          lskv = fetchLatestKernelVersion "stable";
          lmkv = fetchLatestKernelVersion "mainline";
          clv = "uname -a | cut -f3 -d' ' | cut -f 1 -d'-' ";
          k = "kubectl";
          claude = lib.getExe pkgs.dev.johnrinehart.claude-code-nix;
          codex = lib.getExe pkgs.dev.johnrinehart.codex-cli-nix;
          chess = "scid";
          sudo-nixos-rebuild-flake = "sudo nixos-rebuild switch --flake $HOME/code/repos/mine/nix"; # https://askubuntu.com/questions/22037/aliases-not-available-when-using-sudo
        };

      oh-my-zsh = {
        enable = true;
        plugins = [
          "git"
          "sudo"
          "docker"
          "kubectl"
          "fzf"
        ];
        theme = "agnoster";
      };

      initContent =
        let
          bgimg = builtins.path {
            path = ../../static/full-moon-forest-night-dark-starry-sky-5k-8k-7952x5304-1684.jpg;
            name = "wallpaper.jpg";
          };
          sshSessionLockCfg = osConfig.dev.johnrinehart.sshSessionLock;
          tmuxSocketCfg = osConfig.dev.johnrinehart.tmux;
          sshSessionPackage = pkgs.dev.johnrinehart.ssh-session.override {
            inherit (tmuxSocketCfg) socketDir socketName;
            sessionNamePrefix = sshSessionLockCfg.multiplexerSessionName;
            tmux = pkgs.dev.johnrinehart.tmux;
          };
          multiplexerAutoAttach =
            lib.optionalString
              (
                sshSessionLockCfg.enable
                && sshSessionLockCfg.forceInteractiveShellsIntoMultiplexer
                && sshSessionLockCfg.terminalMultiplexer == "tmux"
              )
              ''
                if [[ -n "$SSH_TTY" && -z "$TMUX" && "''${SSH_SESSION_NO_TMUX:-}" != 1 ]]; then
                  exec ${lib.getExe sshSessionPackage} new
                fi
              '';
          kittySshIntegration = lib.optionalString kittyIntegrationEnabled ''
            # Keep zsh SSH completion while using KiTTY's remote-shell integration.
            ssh() { kitty +kitten ssh "$@" }
          '';
        in
        ''
          ${multiplexerAutoAttach}

          ${kittySshIntegration}

              export BGIMG="${bgimg}"
              if [ ! -f $BGIMG ]; then
              curl -o $BGIMG "https://images.wallpapersden.com/image/download/ocean-sea-horizon_ZmpraG2UmZqaraWkpJRnamtlrWZpaWU.jpg"
              fi

          # zoxide - smarter cd (uses 'j' command like jump did)
              command -v zoxide &>/dev/null && eval "$(zoxide init zsh --cmd j)"


          # https://github.com/nix-community/nix-direnv
              eval "$(direnv hook zsh)"

          # https://blog.vghaisas.com/zsh-beep-sound/
              unsetopt BEEP

              eval $("${lib.getExe pkgs.oh-my-posh}" init zsh --config "${ohMyPoshConfig}");
              _omp_get_prompt() {
                local type=$1 ref branch
                local args=("''${@[2,-1]}")
                if ref=$(git symbolic-ref --quiet HEAD 2>/dev/null); then
                  case "$ref" in
                    refs/repo-manager/*/heads/*) branch="''${ref#*/heads/}" ;;
                    refs/heads/*) branch="''${ref#refs/heads/}" ;;
                    *) branch="$ref" ;;
                  esac
                fi
                OMP_GIT_BRANCH="$branch" POSH_SESSION_ID= $_omp_executable print $type --config "${ohMyPoshConfig}" --shell=zsh --shell-version=$ZSH_VERSION --status=$_omp_status --no-status=$_omp_no_status --execution-time=$_omp_execution_time --job-count=$_omp_job_count --stack-count=$_omp_stack_count --terminal-width="''${COLUMNS-0}" ''${args[@]}
              }
        '';
    };

    home.stateVersion = "24.05";

    manual.manpages.enable = false;
  };
}
