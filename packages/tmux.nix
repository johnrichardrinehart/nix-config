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
  }
)
