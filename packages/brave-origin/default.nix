# Brave Origin: Brave without rewards, wallet, and AI features. It ships from
# the same brave/brave-browser release as brave; keep the versions equal.
import ../brave/make-brave.nix rec {
  pname = "brave-origin";
  version = "1.99.56";

  archives = {
    aarch64-linux = {
      url = "https://github.com/brave/brave-browser/releases/download/v${version}/brave-origin_${version}_arm64.deb";
      hash = "sha256-YXDY/Tz5KOwVJ0PSzykNCLdZjW2E8DzZtUCASacWny0=";
    };
    x86_64-linux = {
      url = "https://github.com/brave/brave-browser/releases/download/v${version}/brave-origin_${version}_amd64.deb";
      hash = "sha256-tamLNby63nb9MrOzIkHdKGzGXvRSrlnczx8NrAJne68=";
    };
    aarch64-darwin = {
      url = "https://github.com/brave/brave-browser/releases/download/v${version}/Brave-Origin-arm64.dmg";
      hash = "sha256-jt6bohOpnul2NBPxVa9pLyOacjWbIuHb49r3NAv3AdI=";
    };
  };

  flavor = "origin";
  optStem = "brave-origin";
  fileStem = "brave-origin";
  appIdStem = "com.brave.Origin";
  darwinStem = "Brave Origin";
  changelogFile = "CHANGELOG_DESKTOP_ORIGIN.md";
  homepage = "https://brave.com/origin/";
  innerBinary = "brave";
}
