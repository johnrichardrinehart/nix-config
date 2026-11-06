# nixpkgs removed brave and brave-origin ("brave: drop", nixpkgs#582838), so
# this repository packages them. make-brave.nix is the last nixpkgs
# expression. Keep version equal to brave-origin's. Track
# https://github.com/brave/brave-browser/releases/latest for security fixes.
import ./make-brave.nix rec {
  pname = "brave";
  version = "1.99.55";

  archives = {
    aarch64-linux = {
      url = "https://github.com/brave/brave-browser/releases/download/v${version}/brave-browser_${version}_arm64.deb";
      hash = "sha256-r5nwaDDQllA/Zmezb/btbEVf7vUgPw0o/vTP065e4Qo=";
    };
    x86_64-linux = {
      url = "https://github.com/brave/brave-browser/releases/download/v${version}/brave-browser_${version}_amd64.deb";
      hash = "sha256-Nk6VSirYTVuj4OIXoinVhzxK5xB9FeYSDkIHUpU5yI0=";
    };
    aarch64-darwin = {
      url = "https://github.com/brave/brave-browser/releases/download/v${version}/Brave-Browser-arm64.dmg";
      hash = "sha256-Bd0wDZP2zHtWybW5XPutX6y9WmrowffQ1r4NFi+HCx0=";
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
