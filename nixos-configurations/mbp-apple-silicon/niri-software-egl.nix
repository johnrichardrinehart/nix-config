_: {
  # niri rejects a software EGL device outright - the ensure! near the top of
  # Tty::try_initialize_gpu in src/backend/tty.rs - and QEMU's virtio-gpu has no
  # virglrenderer behind it on a macOS host, so Mesa offers only llvmpipe. The
  # compositor therefore starts with no renderer and no outputs at all, which
  # leaves the SPICE displays blank and makes the guest agent report a 0x0
  # desktop that spice-vdagentd discards as coming from an old agent.
  #
  # niri-wm/niri#3959, an open pull request, accepts a software EGL device on
  # the primary node and disables dma-buf and DRM leasing while it renders. The
  # second patch comes from niri-wm/niri#4614, which was closed in favour of
  # #3959: virtio-gpu's render node cannot back the software renderer, so with
  # NIRI_ALLOW_SOFTWARE_EGL set (base.nix) niri keeps the render-drm-device
  # that base.nix pins (card0) as its render node, and the renderer lookup
  # finds the GPU that Smithay registered. Carry both until a release includes
  # equivalent support.
  #
  # The hook is pkgs.niri rather than programs.niri.package because
  # greetd+niri.nix derives its compositor with
  # `pkgs.niri.overrideAttrs (old: { patches = (old.patches or []) ++ ... })`,
  # so whatever is added here is carried into the package it actually installs.
  # Neither patch touches a Cargo file, so the cargoDeps hash pinned there
  # stays valid.
  nixpkgs.overlays = [
    (_final: prev: {
      niri = prev.niri.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          # https://github.com/niri-wm/niri/pull/3959
          (prev.fetchpatch2 {
            name = "render-allow-software-rendering-as-last-resort.patch";
            url = "https://github.com/niri-wm/niri/commit/b01319783309c41eddb4e10ed1f8ab55847101bd.patch?full_index=1";
            hash = "sha256-BAmHDvJqZwH2Yhw+6PPUBSlacgueX8WiFn1HGxstIRo=";
          })
          # https://github.com/niri-wm/niri/pull/4614
          (prev.fetchpatch2 {
            name = "tty-honor-configured-node-for-software-egl.patch";
            url = "https://github.com/johnrichardrinehart/niri/commit/38982c5f59ef94afd9f6795669e39518540bccd0.patch?full_index=1";
            hash = "sha256-EH5JbAzNOJTZsgXtSEjwreDvO1LxS/REcy1E3xAtjeo=";
          })
        ];
      });
    })
  ];
}
