# Chromium with a fix for invisible app-modal dialogs on Wayland.
#
# On Wayland, Chromium moves an app-modal dialog (for example "Leave site?")
# into a display's work area with screen coordinates that Wayland does not
# provide. When no output covers the browser's assumed (0, 0) origin, the
# dialog lands outside its window and every browser window ignores input.
# Brave carries the same code, so this build proves the fix for Brave too.
#
# The patch is the landed commit of https://crrev.com/c/8620314, which fixes
# https://issues.chromium.org/issues/575925050. Delete this package when the
# packaged Chromium contains that commit. Nothing installs this package:
# build it on a big-parallel builder to test the fix.
{
  chromium,
  fetchpatch,
  runCommand,
}:

let
  browser = chromium.browser.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      (fetchpatch {
        name = "views-keep-app-modal-dialogs-inside-their-window.patch";
        url = "https://chromium.googlesource.com/chromium/src/+/bd621a485053090977a286bb723ad369f11e48d4^!?format=TEXT";
        decode = "base64 -d";
        # Apply the code change only. The AUTHORS entry does not affect the build.
        includes = [ "chrome/browser/ui/views/chrome_javascript_app_modal_view_factory_views.cc" ];
        hash = "sha256-SFAzCEsoBlQHV3wnTUfWtAmu6coZHXPrzL2kk0NrUwY=";
      })
    ];
  });
in
runCommand "chromium-app-modal-dialog-fix-${browser.version}"
  {
    passthru = { inherit browser; };
    inherit (browser) meta;
  }
  ''
    mkdir -p $out/bin
    substitute ${chromium}/bin/chromium $out/bin/chromium \
      --replace-fail ${chromium.browser} ${browser}
    chmod +x $out/bin/chromium
  ''
