{ tuigreet }:

# The patch adds `--biometric-cmd`. The greeter runs that command with the
# username appended when the user presses Alt+F during login. The Linux console
# sends Super as Alt, so Super+Alt+F starts a face scan at login instead of
# typing "f".
tuigreet.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ../patches/tuigreet-biometric-command.patch ];
})
