{
  coreutils,
  lib,
  sessionNamePrefix ? "ssh",
  socketDir ? "/tmp",
  socketName ? "default",
  tmux,
  writeShellApplication,
}:

writeShellApplication {
  name = "ssh-session";

  text = ''
    tmux_socket_dir=${lib.escapeShellArg socketDir}
    tmux_socket_name=${lib.escapeShellArg socketName}
    session_name_prefix=${lib.escapeShellArg sessionNamePrefix}
    tmux_user_socket_dir="$tmux_socket_dir/tmux-$(${lib.getExe' coreutils "id"} -u)"
    tmux_socket="$tmux_user_socket_dir/$tmux_socket_name"
    tmux_command=(${lib.getExe tmux} -S "$tmux_socket")


    usage() {
      cat <<'EOF'
    Usage:
      ssh-session new [NAME]
      ssh-session list
      ssh-session attach HANDLE_OR_NAME
      ssh-session shell
    EOF
    }

    fail() {
      printf 'ssh-session: %s\n' "$1" >&2
      exit 1
    }

    resolve_target() {
      local request=$1
      local number

      case "$request" in
        =*)
          printf '%s\n' "$request"
          ;;
        s[0-9]*)
          number="''${request#s}"
          case "$number" in
            *[!0-9]*) printf '=%s\n' "$request" ;;
            *) printf '$%s\n' "$number" ;;
          esac
          ;;
        *)
          printf '=%s\n' "$request"
          ;;
      esac
    }

    direct_shell() {
      [ "$#" -eq 0 ] || fail "shell accepts no arguments"
      [ -n "''${SHELL:-}" ] && [ -x "$SHELL" ] || fail "SHELL must name an executable"

      export SSH_SESSION_NO_TMUX=1
      exec "$SHELL" -l
    }

    create_session() {
      local session_id
      local session_name

      [ "$#" -le 1 ] || fail "new accepts at most one name"
      ${lib.getExe' coreutils "install"} -d -m 0700 "$tmux_user_socket_dir"


      if [ "$#" -eq 1 ]; then
        [ -n "$1" ] || fail "session name must not be empty"
        session_name=$1
      else
        session_name="$session_name_prefix-$(${lib.getExe' coreutils "date"} +%Y%m%dT%H%M%S)-$$"
      fi

      session_id=$("''${tmux_command[@]}" new-session -d -P -F '#{session_id}' -s "$session_name")
      if ! "''${tmux_command[@]}" set-option -t "$session_id" @ssh-session 1; then
        "''${tmux_command[@]}" kill-session -t "$session_id" 2>/dev/null || true
        fail "could not mark the new session"
      fi

      exec "''${tmux_command[@]}" attach-session -t "$session_id"
    }

    list_sessions() {
      [ "$#" -eq 0 ] || fail "list accepts no arguments"

      printf 'HANDLE NAME STATE\n'
      "''${tmux_command[@]}" list-sessions \
        -f '#{==:#{@ssh-session},1}' \
        -F '#{s/^\$/s/:session_id} #{session_name} #{?session_attached,attached,detached}' \
        2>/dev/null || true
    }

    attach_session() {
      local managed
      local target

      [ "$#" -eq 1 ] || fail "attach requires one handle or session name"
      target=$(resolve_target "$1")

      if ! "''${tmux_command[@]}" has-session -t "$target" 2>/dev/null; then
        fail "session '$1' does not exist"
      fi

      managed=$("''${tmux_command[@]}" show-options -qv -t "$target" @ssh-session)
      [ "$managed" = 1 ] || fail "session '$1' was not created for SSH"

      exec "''${tmux_command[@]}" attach-session -t "$target"
    }

    command="''${1:-}"
    if [ "$#" -gt 0 ]; then
      shift
    fi

    case "$command" in
      new) create_session "$@" ;;
      shell) direct_shell "$@" ;;
      list) list_sessions "$@" ;;
      attach) attach_session "$@" ;;
      help|-h|--help) usage ;;
      "") usage; exit 1 ;;
      *) fail "unknown command '$command'" ;;
    esac
  '';
}
