# Answers a browser's passkey QR code with KeePassXC. The flake only builds
# for Linux; elsewhere there is no package, and packages/default.nix leaves it
# out.
{ keepassxc-hybrid, system }:

keepassxc-hybrid.packages.${system}.keepassxc-hybrid or null
