# Brave Origin: Brave without rewards, wallet, and AI features. It ships from
# the same brave/brave-browser release as brave; keep the versions equal.
import ../brave/make-brave.nix rec {
  pname = "brave-origin";
  version = "1.100.58";

  archives = {
    aarch64-linux = {
      url = "https://github.com/brave/brave-browser/releases/download/v${version}/brave-origin_${version}_arm64.deb";
      hash = "sha256-SIi0/06IYTq3/Lhe5AfqoYWBsvbqrdnBdaQ7jOJ7pvE=";
    };
    x86_64-linux = {
      url = "https://github.com/brave/brave-browser/releases/download/v${version}/brave-origin_${version}_amd64.deb";
      hash = "sha256-TM7BTRt8Nkh+HYShyrQkq5TpO5S0F2IG5MEaMiE9xh0=";
    };
    aarch64-darwin = {
      url = "https://github.com/brave/brave-browser/releases/download/v${version}/Brave-Origin-arm64.dmg";
      hash = "sha256-nwAA3apGG1FzAtNpNfKssIZWJF1XULnIYG5jeRlwbkI=";
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
