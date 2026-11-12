# nixpkgs removed brave and brave-origin ("brave: drop", nixpkgs#582838), so
# this repository packages them. make-brave.nix is the last nixpkgs
# expression. Keep version equal to brave-origin's. Track
# https://github.com/brave/brave-browser/releases/latest for security fixes.
import ./make-brave.nix rec {
  pname = "brave";
  version = "1.99.56";

  archives = {
    aarch64-linux = {
      url = "https://github.com/brave/brave-browser/releases/download/v${version}/brave-browser_${version}_arm64.deb";
      hash = "sha256-LOHHJU2azfLo/hV2HkaeMUMidIc8hEh3PbGwukDxhhg=";
    };
    x86_64-linux = {
      url = "https://github.com/brave/brave-browser/releases/download/v${version}/brave-browser_${version}_amd64.deb";
      hash = "sha256-W1r00Qh1j+XoK3yxGa8gOXepD8s0ubBzGTF/hj84vHI=";
    };
    aarch64-darwin = {
      url = "https://github.com/brave/brave-browser/releases/download/v${version}/Brave-Browser-arm64.dmg";
      hash = "sha256-YMTAvoDt+pEWiAX4B6RZgPYnOJbicS4hebZ9nWHr25M=";
    };
  };

  flavor = "browser";
  optStem = "brave";
  fileStem = "brave-browser";
  appIdStem = "com.brave.Browser";
  darwinStem = "Brave Browser";
  changelogFile = "CHANGELOG_DESKTOP.md";
  homepage = "https://brave.com/";
  innerBinary = "brave";
}
