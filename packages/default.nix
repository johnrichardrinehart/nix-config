# Custom packages for JohnOS
#
# Only those available on the platform they are evaluated for: the flake
# exports this set for every system, and some packages (the Framework EC
# tools, Moonshine) only build on x86_64-linux. Packages taken from a flake
# with no build for this system are null.
{ pkgs }:

pkgs.lib.filterAttrs (
  _: package: package != null && pkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform package
) pkgs.dev.johnrinehart
