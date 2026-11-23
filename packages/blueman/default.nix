{ blueman }:

# blueman-applet notifies on every Connected flip. A Bluetooth keyboard that
# drops out and reconnects a few seconds later stacks up Disconnected and
# Connected notifications for a link that never really went away. The patch
# still shows Disconnected at once, but closes it and skips Connected when the
# device reconnects within 30 seconds.
blueman.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./0001-connection-notifier-grace-period.patch ];
})
