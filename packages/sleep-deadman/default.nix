# sleep_deadman: a kernel module that panics, and so reboots, when a
# hibernation hangs, and prints the blocked tasks first so pstore keeps
# where it hung. See sleep_deadman.c. Take kernel and
# kernelModuleMakeFlags from the same kernelPackages.
{
  kernel,
  kernelModuleMakeFlags,
  lib,
  stdenv,
  xz,
}:
stdenv.mkDerivation {
  pname = "sleep-deadman";
  version = "1-${kernel.version}";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Kbuild
      ./sleep_deadman.c
    ];
  };

  # modules_install compresses the module as the kernel does (xz).
  nativeBuildInputs = kernel.moduleBuildDependencies ++ [ xz ];

  preBuild = ''
    export SLEEP_DEADMAN_SRC=$PWD
  '';

  makeFlags = kernelModuleMakeFlags ++ [
    "-C"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "M=$(SLEEP_DEADMAN_SRC)"
  ];

  buildFlags = [ "modules" ];

  # NixOS runs depmod over all module packages together.
  installFlags = [
    "INSTALL_MOD_PATH=${placeholder "out"}"
    "INSTALL_MOD_DIR=extra/sleep-deadman"
    "DEPMOD=true"
  ];
  installTargets = [ "modules_install" ];

  meta = {
    description = "Kernel module that panics and reboots when a hibernation hangs";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
  };
}
