# Brave Origin: Brave without rewards, wallet, and AI features. It ships from
# the same brave/brave-browser release as brave; keep the versions equal.
import ../brave/make-brave.nix rec {
  pname = "brave-origin";
  version = "1.99.55";

  archives = {
    aarch64-linux = {
      url = "https://github.com/brave/brave-browser/releases/download/v${version}/brave-origin_${version}_arm64.deb";
      hash = "sha256-WSxFq+JX35bO1zFzbbuC/eHPlbiX75hIo0R1dmluOSs=";
    };
    x86_64-linux = {
      url = "https://github.com/brave/brave-browser/releases/download/v${version}/brave-origin_${version}_amd64.deb";
      hash = "sha256-YxmkjQ/8IF+FW4wkI/cKy19jtoghTxG7W2EL0xeT/Gs=";
    };
    aarch64-darwin = {
      url = "https://github.com/brave/brave-browser/releases/download/v${version}/Brave-Origin-arm64.dmg";
      hash = "sha256-wbGEeVZUKdYw2CbOJnlv6zK4Uncmre8u0v4XWYMXFZE=";
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
