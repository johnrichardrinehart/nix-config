# The thunderbolt (USB4) driver built out of tree from the kernel's own
# source, with ./patches applied. It installs under updates/, which depmod
# searches before the in-tree kernel/ copy, so it replaces the kernel's
# thunderbolt.ko without a kernel rebuild. Docks, USB4 displays and the
# initrd depend on it, so switch and reboot rather than reloading it.
#
# Patches must not change the driver's exported interfaces: the modules
# that use them (typec, thunderbolt_net, ...) stay in tree. Take kernel
# and kernelModuleMakeFlags from the same kernelPackages.
{
  kernel,
  kernelModuleMakeFlags,
  lib,
  stdenv,
  xz,
}:
let
  driverDir = "drivers/thunderbolt";
in
stdenv.mkDerivation {
  pname = "thunderbolt";
  inherit (kernel) src version;

  # Only the driver: the kernel's build tree comes from kernel.dev.
  unpackPhase = ''
    runHook preUnpack
    tar -xf $src --wildcards '*/${driverDir}/*'
    sourceRoot=$(echo linux-*)
    export THUNDERBOLT_SRC=$PWD/$sourceRoot/${driverDir}
    runHook postUnpack
  '';

  patches = lib.sort (a: b: a < b) (lib.filesystem.listFilesRecursive ./patches);

  # modules_install compresses the modules as the kernel does (xz).
  nativeBuildInputs = kernel.moduleBuildDependencies ++ [ xz ];

  enableParallelBuilding = true;

  makeFlags = kernelModuleMakeFlags ++ [
    "-C"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "M=$(THUNDERBOLT_SRC)"
  ];

  buildFlags = [ "modules" ];

  # NixOS runs depmod over all module packages together.
  installFlags = [
    "INSTALL_MOD_PATH=${placeholder "out"}"
    "INSTALL_MOD_DIR=updates/thunderbolt"
    "DEPMOD=true"
  ];
  installTargets = [ "modules_install" ];

  meta = {
    description = "thunderbolt (USB4) driver from the kernel source, with local patches";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
  };
}
