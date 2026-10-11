{ fetchFromGitHub, tmux }:

tmux.overrideAttrs (
  finalAttrs: _old: {
    version = "3.8";

    src = fetchFromGitHub {
      owner = "tmux";
      repo = "tmux";
      tag = finalAttrs.version;
      hash = "sha256-pv2wlr3coo+E0pfpb58giJJQn9PGgMFqtVA6nk+9JdE=";
    };

    # 3.8 contains upstream e5a2a25 (patched into 3.6a by nixpkgs) and 31c93c4,
    # both fixes for partially initialized control-mode clients.
    patches = [ ];
  }
)
