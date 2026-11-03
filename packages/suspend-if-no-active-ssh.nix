{
  confirmSshActivityCommand ? "",
  # Process name of the screen locker that the idle policy starts before this
  # script runs. When set, the suspend is canceled if no such process is
  # running at suspend time: someone unlocked the session, so the user is back.
  # This covers a resume that hypridle ignores because an idle inhibitor was
  # held at that moment, which leaves this script running.
  lockerProcessName ? "",
  suspendVerb ? "suspend-then-hibernate",
  writeShellScriptBin,
  coreutils,
  libnotify,
  procps,
  systemd,
}:

writeShellScriptBin "suspend-if-no-active-ssh" ''
  set -eu

  if [ -n "${confirmSshActivityCommand}" ]; then
    if ! ${confirmSshActivityCommand}; then
      ${libnotify}/bin/notify-send -u normal 'Suspend canceled because SSH activity was detected'
      exit 0
    fi
  fi

  if [ -n "${lockerProcessName}" ] \
    && ! ${procps}/bin/pgrep -x -u "$(${coreutils}/bin/id -u)" '${lockerProcessName}' >/dev/null; then
    ${libnotify}/bin/notify-send -u normal 'Suspend canceled because the session was unlocked'
    exit 0
  fi

  ${systemd}/bin/systemctl ${suspendVerb}
''
