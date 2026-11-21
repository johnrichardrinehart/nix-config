{ wl-gammarelay-rs }:

# niri reports gamma_control `failed` when it cannot set GAMMA_LUT, which
# happens transiently on resume when logind revokes DRM master before niri
# handles the session pause. Upstream wl-gammarelay-rs then drops the output
# for good while its D-Bus interface keeps accepting values, and niri keeps
# restoring the last LUT it managed to set, so the panel stays frozen at the
# pre-suspend brightness and temperature. The patch keeps the output and
# requests a new gamma control with backoff (250 ms doubling to 30 s).
wl-gammarelay-rs.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ../patches/wl-gammarelay-rs-retry-failed-gamma-control.patch ];
})
