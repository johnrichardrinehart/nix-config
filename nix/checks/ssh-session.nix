{ lib, pkgs }:
let
  socketDir = "/tmp";
  socketName = "ssh-session-check";
  tmux = pkgs.dev.johnrinehart.tmux;
  sshSession = pkgs.dev.johnrinehart.ssh-session.override {
    inherit socketDir socketName tmux;
    sessionNamePrefix = "automatic";
  };
  mockShell = pkgs.writeShellScript "ssh-session-test-shell" ''
    printf 'bypass=%s\nargs=%s\n' "$SSH_SESSION_NO_TMUX" "$*" > "$SSH_SESSION_TEST_OUTPUT"
  '';
  tmuxCommand = "${lib.getExe tmux} -S ${socketDir}/tmux-$(${lib.getExe' pkgs.coreutils "id"} -u)/${socketName}";
in
pkgs.runCommand "ssh-session-tests"
  {
    nativeBuildInputs = [ pkgs.util-linux ];
  }
  ''
    export HOME="$TMPDIR/home"
    export TERM=xterm-256color
    mkdir -p "$HOME"

    cleanup() {
      ${tmuxCommand} kill-server 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM HUP
    export SSH_SESSION_TEST_OUTPUT="$TMPDIR/direct-shell"
    SHELL=${mockShell} ${lib.getExe sshSession} shell
    grep -Fx bypass=1 "$SSH_SESSION_TEST_OUTPUT"
    grep -Fx args=-l "$SSH_SESSION_TEST_OUTPUT"


    ${lib.getExe' pkgs.coreutils "install"} -d -m 0700 "${socketDir}/tmux-$(${lib.getExe' pkgs.coreutils "id"} -u)"
    ${tmuxCommand} new-session -d -s local-session
    ${tmuxCommand} set-hook -g client-attached detach-client
    script --quiet --return --command '${lib.getExe sshSession} new initial-name' /dev/null </dev/null

    session_id=$(${tmuxCommand} list-sessions -f '#{==:#{@ssh-session},1}' -F '#{session_id}')
    test "$(${tmuxCommand} show-options -qv -t "$session_id" @ssh-session)" = 1

    ${tmuxCommand} rename-session -t "$session_id" human-name
    test "$(${tmuxCommand} show-options -qv -t "$session_id" @ssh-session)" = 1

    handle="s''${session_id#\$}"
    ${lib.getExe sshSession} list > sessions
    grep -F "$handle" sessions
    grep -F human-name sessions
    ! grep -F local-session sessions

    script --quiet --return --command "${lib.getExe sshSession} attach $handle" /dev/null </dev/null
    test "$(${tmuxCommand} display-message -p -t "$session_id" '#{session_attached}')" = 0

    if ${lib.getExe sshSession} attach local-session 2> error; then
      echo "attached to an unmarked session" >&2
      exit 1
    fi
    grep -F "was not created for SSH" error

    touch "$out"
  ''
