{ blueman }:

# blueman-applet notifies on every Connected flip. A Bluetooth keyboard that
# drops out and reconnects a few seconds later stacks up Disconnected and
# Connected notifications for a link that never really went away. The patch
# holds Disconnected back for 30 seconds and shows neither notification when
# the device reconnects within that time.
blueman.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./0001-connection-notifier-grace-period.patch ];
})
