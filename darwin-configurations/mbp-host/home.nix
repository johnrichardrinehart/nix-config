# Home Manager configuration for john on the Mac host.
{
  config,
  inputs,
  lib,
  pkgs,
  # Signed copies outside the store (default.nix), installed by provision-mac.
  shoteditBin,
  displaySeamsBin,
  mightyMittsBin,
  ...
}:
let
  cfg = config.dev.johnrinehart.mbp-host;
  # One build for PATH and the activation step below.
  displayMode = pkgs.callPackage ../../packages/display-mode/package.nix { };

  # Remote URL shapes of a GitHub owner's repositories, for `hasconfig`.
  ownerPatterns = owner: [
    "**/${owner}/**"
    "*:${owner}/**"
  ];
in
{
  options.dev.johnrinehart.mbp-host.github.personalSshKey = lib.mkOption {
    type = lib.types.str;
    default = "~/.ssh/id_ed25519_github.com_johnrichardrinehart";
    description = ''
      SSH key that authenticates as github.com/johnrichardrinehart. Pinned for
      all of github.com so that, with several GitHub keys in the agent, ssh
      does not authenticate as whichever account's key happens to come first.
    '';
  };

  options.dev.johnrinehart.mbp-host.github.ownerIdentities = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          owners = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = ''
              GitHub owners (users or organizations) whose repositories use this
              identity. The match is case-sensitive, and a miss is silent: the
              commit is authored as the personal identity and only refused at
              push. List every spelling the remotes carry.
            '';
          };
          sshKey = lib.mkOption {
            type = lib.types.str;
            description = "SSH key that authenticates as the account that owns these repositories.";
          };
          git = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
            example = {
              user.email = "me@example.com";
              commit.gpgsign = true;
            };
            description = "Git config for these repositories (identity, signing).";
          };
        };
      }
    );
    default = { };
    description = ''
      GitHub accounts besides the personal one, each with its own key. For
      repositories of the listed owners, Git takes the identity and SSH
      command from `git`, selected by remote URL in the global config (the Mac
      has no repo-manager-written repository config), and their SSH remotes
      are rewritten to the alias github-<name>, which pins `sshKey`.
      Everything else on github.com keeps the personal key.
    '';
  };

  config = {
    home.stateVersion = "26.05";

    home.packages = [
      pkgs.htop
      displayMode
      pkgs.tmux
      pkgs.tree
      pkgs.watch
      pkgs.wormhole-rs
      pkgs.ripgrep
      pkgs.fd
      pkgs.ncdu
      # GNU timeout alone: all of coreutils would shadow macOS's date, ls, sed...
      (pkgs.runCommand "timeout" { } ''
        mkdir -p $out/bin
        ln -s ${pkgs.coreutils}/bin/timeout $out/bin/timeout
      '')
      pkgs.repo-manager
      inputs.self.packages.aarch64-darwin.mbp-apple-silicon-qemu-vm
      # Its viewer, Spicy.app, which Home Manager copies into
      # ~/Applications/Home Manager Apps; the launcher runs that copy.
      inputs.self.packages.aarch64-darwin.mbp-apple-silicon-qemu-vm.spicy
      # The same floating wrapper the NixOS machines install
      # (nixosModules agentTools.omp): it `nix run`s llm-agents.nix's omp,
      # rechecked hourly, with the context-mode extension.
      (inputs.self.packages.aarch64-darwin.omp.withPlugins (p: [ p.context-mode ]))
    ];

    # One full-screen editor for both: every program honors at least one.
    home.sessionVariables = {
      EDITOR = "vim";
      VISUAL = "vim";

      # Render colour escapes in less (`jq -C … | less`). nix-darwin only puts
      # -R in PAGER, which commands piping into less never see. NixOS hosts
      # get LESS=-R from programs.less, on by default.
      LESS = "-R";
    };

    # /usr/bin/git and /usr/bin/vim are Xcode shims (git refuses to run until
    # the Xcode license is accepted); the Nix ones come first on PATH.
    programs.vim = {
      enable = true;
      # nixpkgs' default vim is built for X11 (GTK2), so "+ and "* went to an
      # X clipboard nobody runs. vim-darwin uses the macOS pasteboard, which
      # is also what spicy shares with the guest.
      packageConfigurable = pkgs.vim-darwin;
      extraConfig = ''
        set encoding=utf-8
        set number

        " Tell tabs from spaces: a tab shows as », a leading space as a dim ·.
        set list
        set listchars=tab:»\ ,lead:·,trail:·,nbsp:␣

        " Trailing whitespace in red, except just behind the cursor while
        " typing. Re-applied on colorscheme changes, which clear it.
        highlight ExtraWhitespace ctermbg=red guibg=red
        augroup ExtraWhitespace
          autocmd!
          autocmd ColorScheme * highlight ExtraWhitespace ctermbg=red guibg=red
          autocmd BufWinEnter,InsertLeave * match ExtraWhitespace /\s\+$/
          autocmd InsertEnter * match ExtraWhitespace /\s\+\%#\@<!$/
        augroup END

        " :WipeTrailingSpace strips it from the whole file, or from a range
        " (:'<,'>WipeTrailingSpace), keeping the cursor and search history.
        function! s:WipeTrailingSpace(first, last) abort
          let l:view = winsaveview()
          keeppatterns execute a:first . ',' . a:last . 's/\s\+$//e'
          call winrestview(l:view)
        endfunction
        command! -range=% WipeTrailingSpace call s:WipeTrailingSpace(<line1>, <line2>)
      '';
    };

    programs.zsh = {
      enable = true;
      initContent = ''
        # zsh picks the vi keymap whenever $EDITOR/$VISUAL contain "vi"
        # (silently unbinding ^A, ^R, ...). Line editing stays emacs.
        bindkey -e

        # Word motions (Alt+Backspace, ^W, Alt-b/f) treat only alphanumerics as
        # word characters, so they stop at / - . _ like the NixOS hosts.
        WORDCHARS=""

        # Ctrl+Left/Right: word movement
        bindkey "^[[1;5D" backward-word
        bindkey "^[[1;5C" forward-word

        # Colour ls by entry type with whichever ls is on PATH. oh-my-zsh
        # aliases ls='ls -G' for macOS's BSD ls at startup, but a Nix dev
        # shell (direnv) puts GNU ls first, which reads -G as --no-group and
        # needs --color. zsh rehashes on every PATH change, so this follows
        # direnv in and out. LS_COLORS (GNU) and LSCOLORS (BSD) come from
        # oh-my-zsh.
        unalias ls 2>/dev/null
        ls() {
          if [[ ''${commands[ls]} == /bin/ls ]]; then
            command ls -G "$@"
          else
            command ls --color=auto "$@"
          fi
        }
      '';

      # The git aliases (gst, glg, gd, gaa, ggl, ...) the NixOS hosts have.
      # oh-my-posh draws the prompt, so no oh-my-zsh theme.
      oh-my-zsh = {
        enable = true;
        plugins = [ "git" ];
        theme = "";
      };
    };

    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
    };

    # `j <query>` jumps by frecency, `ji` picks interactively.
    programs.zoxide = {
      enable = true;
      options = [
        "--cmd"
        "j"
      ];
    };

    # Same prompt as the NixOS hosts (time, user@host, path, git, status,
    # nix-shell); needs the Nerd Font the system module installs.
    programs.oh-my-posh = {
      enable = true;
      settings = builtins.fromJSON (
        builtins.readFile "${inputs.self.outPath}/home-configurations/home-manager/oh-my-posh.json"
      );
    };

    programs.git = {
      enable = true;
      # The identity follows the repository's remote, not its checkout path:
      # repo-manager keeps bare clones and worktrees in different trees.
      includes =
        map
          (prefix: {
            condition = "hasconfig:remote.*.url:${prefix}johnrichardrinehart/**";
            contents.user = {
              name = "John Rinehart";
              email = "johnrichardrinehart@gmail.com";
            };
          })
          [
            "https://github.com/"
            "git@github.com:"
            "ssh://git@github.com/"
          ]
        ++ lib.concatLists (
          lib.mapAttrsToList (
            _: identity:
            lib.concatMap (
              owner:
              map (pattern: {
                condition = "hasconfig:remote.*.url:${pattern}";
                contents = lib.recursiveUpdate identity.git {
                  core.sshCommand = "ssh -i ${identity.sshKey} -o IdentitiesOnly=yes";
                };
              }) (ownerPatterns owner)
            ) identity.owners
          ) cfg.github.ownerIdentities
        );
      # GitHub over SSH, never HTTPS, as on the NixOS machines (nixosModules
      # common.nix). An HTTPS push would authenticate with whatever
      # ~/.netrc or a credential helper holds, not the key picked by the
      # remote's owner.
      settings.url = {
        "git@github.com:".insteadOf = "https://github.com";
      }
      // lib.listToAttrs (
        lib.concatLists (
          lib.mapAttrsToList (
            name: identity:
            map (owner: {
              name = "git@github-${name}:${owner}/";
              value.insteadOf = [
                "git@github.com:${owner}/"
                "ssh://git@github.com/${owner}/"
              ];
            }) identity.owners
          ) cfg.github.ownerIdentities
        )
      );
      # As on the NixOS machines: a plain `git push` of a branch without an
      # upstream pushes it to the same name on origin and tracks it.
      settings.push.autoSetupRemote = true;
    };

    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;
      settings = {
        "github.com" = {
          HostName = "github.com";
          User = "git";
          IdentityFile = cfg.github.personalSshKey;
          IdentitiesOnly = true;
        };
      }
      # Only reached through the remote rewrites above.
      // lib.mapAttrs' (
        name: identity:
        lib.nameValuePair "github-${name}" {
          HostName = "github.com";
          User = "git";
          IdentityFile = identity.sshKey;
          IdentitiesOnly = true;
        }
      ) cfg.github.ownerIdentities;
    };

    # Cmd+Shift+4 opens the screenshot editor directly (see shotedit.swift).
    launchd.agents.shotedit = {
      enable = true;
      config = {
        ProgramArguments = [ shoteditBin ];
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Interactive";
        StandardErrorPath = "/tmp/shotedit.log";
      };
    };

    # Join display edges macOS leaves as walls: the pointer crosses the whole
    # height of each edge, mapped proportionally (see display-seams/main.swift).
    launchd.agents.display-seams = {
      enable = true;
      config = {
        ProgramArguments = [ displaySeamsBin ];
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Interactive";
        StandardErrorPath = "/tmp/display-seams.log";
      };
    };

    # Menu bar battery levels of both SliceMK halves (packages/mighty-mitts).
    launchd.agents.mighty-mitts = {
      enable = true;
      config = {
        ProgramArguments = [ mightyMittsBin ];
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Interactive";
        StandardErrorPath = "/tmp/mighty-mitts.log";
      };
    };

    # Glance (apps.nix) unlocks the screen only while it runs, and Cmd+Q
    # quits it. `open -W` waits for the running Glance, or starts one, so
    # launchd starts Glance again after it quits without a second instance.
    launchd.agents.glance = {
      enable = true;
      config = {
        ProgramArguments = [
          "/usr/bin/open"
          "-W"
          "-g"
          "-a"
          "/Applications/Glance.app"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        ThrottleInterval = 10;
        ProcessType = "Interactive";
        StandardErrorPath = "/tmp/glance-agent.log";
      };
    };

    home.activation = {
      # System shortcuts (com.apple.symbolichotkeys) turned off, as
      # id = [ ascii keycode modifiers ]. -dict-add leaves every other hotkey
      # alone, so only these are pinned.
      #   30        "Save picture of selected area as a file" (Cmd+Shift+4):
      #             shotedit owns the chord.
      #   79, 81    Mission Control "Move left/right a space" (Ctrl+Left/Right):
      #             they swallow the chords zsh binds to backward/forward-word.
      #   118-120   "Switch to Desktop 1-3" (Ctrl+1..3).
      disabledSymbolicHotkeys = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        ${lib.concatStrings (
          lib.mapAttrsToList
            (id: params: ''
              run /usr/bin/defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys \
                -dict-add ${id} '{ enabled = 0; value = { parameters = (${
                  lib.concatMapStringsSep ", " toString params
                }); type = standard; }; }'
            '')
            {
              "30" = [
                52
                21
                1179648
              ];
              "79" = [
                65535
                123
                8650752
              ];
              "81" = [
                65535
                124
                8650752
              ];
              "118" = [
                65535
                18
                262144
              ];
              "119" = [
                65535
                19
                262144
              ];
              "120" = [
                65535
                20
                262144
              ];
            }
        )}
        run /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
      '';

      # Glance settings, looser than its defaults:
      #   minimumFaceWidth      Glance only scans faces wider than this
      #                         fraction of the camera frame. The Recognition
      #                         page goes down to 0.15 ("Far"); 0.1 lets the
      #                         face be about 1.5 times farther away.
      #   matchThreshold        Similarity to an enrolled face for a match.
      #                         0.45 is below the page's lowest, "Less strict"
      #                         (0.58); Glance's default is 0.66.
      #   faceDetectionSeconds  Length of one scan (default 5, range 3-10):
      #                         more time to blink for Heavy liveness.
      # Changing a setting on the Recognition page writes over these values
      # until the next activation. Glance reads them only when it starts, so
      # restart it after a change. The launchd agent above starts it again.
      # The new Glance session is locked: unlock it from the menu bar item
      # (Touch ID), or face unlock stays off.
      glanceSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        glanceChanged=
        ${lib.concatStrings (
          lib.mapAttrsToList
            (key: value: ''
              if [[ $(/usr/bin/defaults read com.jonathan.glance GlanceSettings.${key} 2>/dev/null) != ${value.shown} ]]; then
                run /usr/bin/defaults write com.jonathan.glance GlanceSettings.${key} ${value.typed}
                glanceChanged=1
              fi
            '')
            {
              minimumFaceWidth = {
                shown = "0.1";
                typed = "-float 0.1";
              };
              matchThreshold = {
                shown = "0.45";
                typed = "-float 0.45";
              };
              faceDetectionSeconds = {
                shown = "8";
                typed = "-int 8";
              };
            }
        )}
        if [[ -n $glanceChanged ]] && /usr/bin/pgrep -qx glance; then
          run /usr/bin/pkill -x glance
          warnEcho "Glance restarted for new settings; unlock its session from the menu bar item."
        fi
      '';

      # Terminal keeps each profile as one nested dictionary (colors and font
      # are archived NSColor/NSFont data), which `defaults write` cannot
      # address. Round-trip the domain through cfprefsd instead: export,
      # replace the "Clear Dark" profile with the committed one (FiraMono Nerd
      # Font Mono 12, Option as Meta, 120x30), make it the default, import.
      terminalProfile = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        tmp=$(mktemp -d)
        plist="$tmp/com.apple.Terminal.plist"
        if ! /usr/bin/defaults export com.apple.Terminal "$plist" 2>/dev/null; then
          printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
            '<plist version="1.0"><dict/></plist>' >"$plist"
        fi
        /usr/bin/plutil -type "Window Settings" "$plist" >/dev/null 2>&1 \
          || /usr/bin/plutil -insert "Window Settings" -dictionary "$plist"
        /usr/bin/plutil -remove "Window Settings.Clear Dark" "$plist" 2>/dev/null || true
        /usr/bin/plutil -insert "Window Settings.Clear Dark" -xml "$(cat ${./terminal-clear-dark.plist})" "$plist"
        /usr/bin/plutil -replace "Default Window Settings" -string "Clear Dark" "$plist"
        /usr/bin/plutil -replace "Startup Window Settings" -string "Clear Dark" "$plist"
        run /usr/bin/defaults import com.apple.Terminal "$plist"
        rm -rf "$tmp"
      '';

      # The 32" Dell U3225QE (vendor 0x10ac, model 0x4376; native 3840x2160)
      # looks like 2560x1440 at scale 2: text 1.5 times its native size. The
      # mode is saved permanently, and WindowServer restores it each time the
      # monitor is attached. When it is not connected, this does nothing.
      # `display-mode list` prints them for another display.
      displayModes = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${lib.getExe displayMode} \
          set 4268 17270 2560 1440 2
      '';
    };

    xdg.configFile = {
      # spicy is the SPICE viewer the VM launcher opens. The launcher runs it
      # with --no-save-settings, and it leaves an unwritable settings file
      # alone anyway, so this link stays put; `force` covers older builds.
      "spicy/settings" = {
        force = true;
        text = lib.generators.toINI { } {
          general = {
            grab-keyboard = true;
            grab-mouse = true;
            scaling = true;
            auto-clipboard = true;
            sync-modifiers = true;
            resize-guest = true;
          };
          ui = {
            toolbar = true;
            statusbar = true;
          };
        };
      };
    };
  };
}
