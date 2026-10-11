{ openvino, fetchFromGitHub }:

openvino.overrideAttrs (
  finalAttrs: _old: {
    version = "2026.4.1";

    src = fetchFromGitHub {
      owner = "openvinotoolkit";
      repo = "openvino";
      tag = finalAttrs.version;
      fetchSubmodules = true;
      hash = "sha256-C1qRg0GX+K5tUui66lvK9RzdInIJzXAKyvjkMyB5ce0=";
    };
  }
)
