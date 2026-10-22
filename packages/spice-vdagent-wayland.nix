{
  alsa-lib,
  autoreconfHook,
  dbus,
  fetchFromGitHub,
  fetchpatch2,
  glib,
  gtk4,
  lib,
  libdrm,
  libpciaccess,
  libxcb,
  libxfixes,
  libxinerama,
  libxrandr,
  pkg-config,
  spice-protocol,
  stdenv,
  systemd,
  wayland,
}:
# spice-vdagent with the Wayland work that upstream 0.23.0 only half has.
# Upstream's --with-gtk4=yes defines USE_GTK_FOR_MONITORS but deliberately not
# USE_GTK_FOR_CLIPBOARD, because its clipboard.c is written against GTK3's
# GtkClipboard, which GTK4 dropped. This fork rewrites that file against
# GdkClipboard and so defines both, which is what makes a Wayland guest able to
# report its layout *and* share a clipboard.
#
# Clipboard is split by direction: host to guest publishes through
# zwlr_data_control_manager_v1 when available and falls back to GdkClipboard;
# guest to host observes through the same data-control protocol. niri
# implements that and wlr-output-management, so both halves land.
stdenv.mkDerivation {
  pname = "spice-vdagent-wayland";
  version = "0.23.2";

  src = fetchFromGitHub {
    owner = "bjthompson805";
    repo = "spice-vdagent-wayland";
    tag = "v0.23.2";
    hash = "sha256-vWRqKdeta0PtAHRjKcxDzl+ve6GzmxtoP9K2BibT9gI=";
  };

  postPatch = ''
    substituteInPlace data/spice-vdagent.desktop --replace-fail /usr "$out"
  '';

  # The tree ships no generated configure, unlike the release tarball nixpkgs
  # builds from.
  nativeBuildInputs = [
    autoreconfHook
    pkg-config
  ];

  buildInputs = [
    alsa-lib
    dbus
    glib
    gtk4
    libdrm
    libpciaccess
    libxcb
    libxfixes
    libxinerama
    libxrandr
    spice-protocol
    systemd
    wayland
  ];

  # Each patch is the head commit of an open pull request against src's
  # repository. johnrichardrinehart/spice-vdagent-wayland's main merges all of
  # them onto src's tag, so its tree is src with these patches applied; move
  # both together.
  #
  # niri answers org.gnome.Mutter.DisplayConfig for its ScreenCast and
  # ServiceChannel interfaces but reports no monitors through it, and the agent
  # treats that empty-but-successful reply as authoritative, never reaching the
  # GTK backend that can see the outputs.
  patches = [
    # https://github.com/bjthompson805/spice-vdagent-wayland/pull/1
    (fetchpatch2 {
      name = "mutter-empty-display-fallback.patch";
      url = "https://github.com/johnrichardrinehart/spice-vdagent-wayland/commit/74c365dec6ecec7f5d7cc9accdd7f6b360a475be.patch?full_index=1";
      hash = "sha256-051+WHnLlOSqZ3NxLggCts6izl9iEpXgIh4ahQ0N9zQ=";
    })
    # A headless agent can never set a wl_data_device selection: that needs a
    # serial from an input event it has no surface to receive. Before this
    # patch, the write side goes through GdkClipboard, so on a compositor that
    # enforces the serial - niri does - the host clipboard reaches the agent
    # and stops dead there. Take the selection over
    # zwlr_data_control_device_v1 instead, which exists precisely for
    # focus-less clipboard ownership.
    # https://github.com/bjthompson805/spice-vdagent-wayland/pull/2
    (fetchpatch2 {
      name = "data-control-clipboard-write.patch";
      url = "https://github.com/johnrichardrinehart/spice-vdagent-wayland/commit/77e62cd24f3671a8b8bdc34a2f53d7a5f4d9d32e.patch?full_index=1";
      hash = "sha256-6639ldKVL1WZJee/QINIFhx81SN3Y3zzseg32otvJb4=";
    })
    # The agent dropped each zwlr_output_mode_v1 as soon as niri announced it,
    # so the next current_mode event named an object libwayland no longer
    # knew - a fatal protocol error. Every resize of the SPICE window changes
    # the guest's mode, so every resize killed the agent. Keep modes until
    # niri finishes them.
    # https://github.com/bjthompson805/spice-vdagent-wayland/pull/3
    (fetchpatch2 {
      name = "output-mode-lifetime.patch";
      url = "https://github.com/johnrichardrinehart/spice-vdagent-wayland/commit/41bf32fb8659755bff2e5e7d574caed8c4d04607.patch?full_index=1";
      hash = "sha256-MUoSMwO8SNFBkcl4UoRUIrOgNQimiThwXQ8NxO5eWgc=";
    })
    # vdagentd kept the old client's capabilities and grab serials when the
    # virtio channel closed, so a restarted agent's first grab went out with a
    # stale serial before the client's handshake reset it. The client and
    # vdagentd then disagreed by one and each discarded the other's grabs:
    # clipboard dead both ways until enough guest copies closed the gap.
    # Forget the client when the channel closes.
    # https://github.com/bjthompson805/spice-vdagent-wayland/pull/4
    (fetchpatch2 {
      name = "clipboard-grab-before-handshake.patch";
      url = "https://github.com/johnrichardrinehart/spice-vdagent-wayland/commit/4303cd8a0db06216990b167f23a75548b660948d.patch?full_index=1";
      hash = "sha256-iS2eKel7mM9fXIKZMngdpeohmMd7aZBwmiRG9y4A8vc=";
    })
    # wl-clip-persist re-offers every selection with its own copy, including
    # the one the agent just set for the host, and the agent grabbed that
    # straight back: the Mac's clipboard was then served from the guest, lost
    # every format the guest lacks (RTF), and emptied whenever the agent went
    # away. Compare such an offer with what was served before announcing it.
    # Applies on top of the data-control patch above.
    # https://github.com/bjthompson805/spice-vdagent-wayland/pull/5
    (fetchpatch2 {
      name = "clipboard-echo.patch";
      url = "https://github.com/johnrichardrinehart/spice-vdagent-wayland/commit/12d3088ad1436c85255d8c1f24fdf7a3bb380717.patch?full_index=1";
      hash = "sha256-BNofNgD6ToPn16PCKhsZxMmRYfBNBcmDkXXSILewSLU=";
    })
  ];

  configureFlags = [ "--with-gtk4=yes" ];

  meta = {
    description = "SPICE guest agent with native Wayland clipboard and monitor support";
    homepage = "https://github.com/bjthompson805/spice-vdagent-wayland";
    license = lib.licenses.gpl3Plus;
    mainProgram = "spice-vdagent";
    platforms = lib.platforms.linux;
  };
}
