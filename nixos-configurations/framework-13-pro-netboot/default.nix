# The Framework 13 Pro booted diskless over PXE: the system runs from RAM and
# nothing touches the disk, until `sudo install-to-disk` installs
# `framework-13-pro` onto it.
{ inputs, ... }:
{
  imports = [
    inputs.self.nixosModules.netboot
    ../framework-13-pro/common.nix
  ];

  dev.johnrinehart.netboot.installer.target = inputs.self.nixosConfigurations.framework-13-pro;
}
