# The Intel iwlwifi drivers (iwlwifi, iwlmvm, iwlmld, iwldvm) built out of
# tree from the kernel's own source, with ./patches applied and
# CONFIG_IWLWIFI_DEBUGFS enabled (the in-tree build has it off). They install
# under updates/, which depmod searches before the in-tree kernel/ copies, so
# they replace the kernel's iwlwifi modules without a kernel rebuild. To try
# a driver change, add a patch with kernel-tree paths (a/drivers/net/...),
# switch, then reload: `modprobe -r iwlmvm iwlwifi && modprobe iwlwifi`.
#
# The debugfs files are under /sys/kernel/debug/iwlwifi/<pci>/iwlmvm/.
# Take kernel and kernelModuleMakeFlags from the same kernelPackages.
{
  kernel,
  kernelModuleMakeFlags,
  lib,
  stdenv,
  xz,
}:
let
  driverDir = "drivers/net/wireless/intel/iwlwifi";
in
stdenv.mkDerivation {
  pname = "iwlwifi";
  inherit (kernel) src version;

  # Only the driver: the kernel's build tree comes from kernel.dev.
  unpackPhase = ''
    runHook preUnpack
    tar -xf $src --wildcards '*/${driverDir}/*'
    sourceRoot=$(echo linux-*)
    export IWLWIFI_SRC=$PWD/$sourceRoot/${driverDir}
    runHook postUnpack
  '';

  patches = lib.sort (a: b: a < b) (lib.filesystem.listFilesRecursive ./patches);

  # modules_install compresses the modules as the kernel does (xz).
  nativeBuildInputs = kernel.moduleBuildDependencies ++ [ xz ];

  # Plain mkDerivation runs make serially; this passes -j/-l from NIX_BUILD_CORES.
  enableParallelBuilding = true;

  makeFlags = kernelModuleMakeFlags ++ [
    "-C"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "M=$(IWLWIFI_SRC)"
    # The Makefiles pick the debugfs objects from the make variable, the C
    # code tests the macro, which the kernel's autoconf.h does not define.
    "CONFIG_IWLWIFI_DEBUGFS=y"
    "KCFLAGS=-DCONFIG_IWLWIFI_DEBUGFS=1"
  ];

  buildFlags = [ "modules" ];

  # NixOS runs depmod over all module packages together.
  installFlags = [
    "INSTALL_MOD_PATH=${placeholder "out"}"
    "INSTALL_MOD_DIR=updates/iwlwifi"
    "DEPMOD=true"
  ];
  installTargets = [ "modules_install" ];

  meta = {
    description = "Intel iwlwifi drivers from the kernel source, with debugfs and local patches";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
  };
}
