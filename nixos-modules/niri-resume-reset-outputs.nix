# After suspend or hibernate, turn each enabled external niri output off and
# on again. Some monitors behind a DisplayPort MST hub stay in standby after
# resume although the link is trained and the stream is in sync; neither the
# kernel nor niri can tell. Turning the output off and on again releases and
# reallocates its MST payload, and the monitor wakes for the new stream.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dev.johnrinehart.niri.resumeResetOutputs;
  primaryUser = config.dev.johnrinehart.users.primary;
  niri = lib.getExe config.programs.niri.package;
  jq = lib.getExe pkgs.jq;
  sleepTargets = [
    "suspend.target"
    "hibernate.target"
    "hybrid-sleep.target"
    "suspend-then-hibernate.target"
  ];
  resetOutputs = pkgs.writeShellScript "niri-resume-reset-outputs" ''
    set -u
    # A system unit has no XDG_RUNTIME_DIR; niri's socket lives in the user's.
    XDG_RUNTIME_DIR=''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
    sleep ${toString cfg.settleSeconds}

    shopt -s nullglob
    sockets=("$XDG_RUNTIME_DIR"/niri.*.sock)
    if (( ''${#sockets[@]} == 0 )); then
      echo "no niri socket in $XDG_RUNTIME_DIR; nothing to do"
      exit 0
    fi

    status=0
    for socket in "''${sockets[@]}"; do
      export NIRI_SOCKET="$socket"
      # Enabled outputs only; internal panels never sit behind an MST hub.
      if ! outputs=$(${niri} msg --json outputs | ${jq} -r '
            .[] | select(.current_mode != null)
            | .name | select(test("^(eDP|LVDS|DSI)-") | not)'); then
        echo "$socket: niri msg outputs failed" >&2
        status=1
        continue
      fi
      for output in $outputs; do
        echo "$socket: resetting $output"
        ${niri} msg output "$output" off || status=1
        sleep ${toString cfg.offSeconds}
        ${niri} msg output "$output" on || status=1
      done
    done
    exit "$status"
  '';
in
{
  options.dev.johnrinehart.niri.resumeResetOutputs = {
    enable = lib.mkEnableOption "turning external niri outputs off and on again after each resume";

    settleSeconds = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 3;
      description = "Seconds to wait after resume before touching outputs, so the MST topology settles.";
    };

    offSeconds = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 2;
      description = "Seconds each output stays off. A manual 2-second off/on woke a Dell U2520D.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.niri-resume-reset-outputs = {
      description = "Turn external niri outputs off and on again after resume";
      after = sleepTargets;
      wantedBy = sleepTargets;
      serviceConfig = {
        Type = "oneshot";
        User = primaryUser;
        ExecStart = resetOutputs;
        TimeoutStartSec = "1min";
      };
    };
  };
}
