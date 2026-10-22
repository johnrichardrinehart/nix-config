{ deluge }:

# Both patches are proposed upstream (deluge-torrent/deluge, branches
# desktop-single-main-window and ipc-activation-token); drop them once a
# release includes them. Relaunching Deluge now raises its window on
# Wayland, and its entry declares SingleMainWindow for launchers.
deluge.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    ./0001-gtk-declare-SingleMainWindow-in-desktop-entry.patch
    ./0002-gtk-forward-XDG-activation-token-to-running-instance.patch
  ];
})
