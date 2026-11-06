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
          # The fork's software-egl-opt-in branch carries it on top of niri main.
          (prev.fetchpatch2 {
            name = "render-allow-software-rendering-as-last-resort.patch";
            url = "https://github.com/johnrichardrinehart/niri/compare/e7a92816d832811f454f507b0afd31cd17938e48...b154a2d4463477d21df5f3f57b719d3f80ab79d6.patch?full_index=1";
            hash = "sha256-1sE4u++jrpuAdMfKEhleLnqTUhNAfxtM5q24gRnXI8k=";
          })
          # https://github.com/niri-wm/niri/pull/4614
          (prev.fetchpatch2 {
            name = "tty-honor-configured-node-for-software-egl.patch";
            url = "https://github.com/johnrichardrinehart/niri/commit/8213eb88f5187001c9d81d29ffe34ed20296bab6.patch?full_index=1";
            hash = "sha256-O7kU24QSvg/KVYZF6Znyc4belMEgg79ZigGCpqwOnW0=";
          })
        ];
      });
    })
  ];
}
