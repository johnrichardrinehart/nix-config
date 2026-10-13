# The display-layout flake only builds for Linux; elsewhere there is no
# package, and packages/default.nix leaves it out.
{
  display-layout,
  system,
}:
display-layout.packages.${system}.default or null
