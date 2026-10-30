# The mt76 Wi-Fi drivers (mt76, mt792x-lib, mt7925e, ...) built out of tree
# from the kernel's own source, with ./patches applied. They install under
# updates/, which depmod searches before the in-tree kernel/ copies, so they
# replace the kernel's mt76 modules without a kernel rebuild. To try a
# driver change, add a patch with kernel-tree paths (a/drivers/net/...),
# switch, then reload: `modprobe -r mt7925e && modprobe mt7925e`.
#
# Every mt76 module is rebuilt, not only the patched one, so their shared
# structures always match. Take kernel and kernelModuleMakeFlags from the
# same kernelPackages.
{
  kernel,
  kernelModuleMakeFlags,
  lib,
  stdenv,
  xz,
}:
let
  driverDir = "drivers/net/wireless/mediatek/mt76";
in
stdenv.mkDerivation {
  pname = "mt76";
  inherit (kernel) src version;

  # Only the driver: the kernel's build tree comes from kernel.dev.
  unpackPhase = ''
    runHook preUnpack
    tar -xf $src --wildcards '*/${driverDir}/*'
    sourceRoot=$(echo linux-*)
    export MT76_SRC=$PWD/$sourceRoot/${driverDir}
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
    "M=$(MT76_SRC)"
  ];

  buildFlags = [ "modules" ];

  # NixOS runs depmod over all module packages together.
  installFlags = [
    "INSTALL_MOD_PATH=${placeholder "out"}"
    "INSTALL_MOD_DIR=updates/mt76"
    "DEPMOD=true"
  ];
  installTargets = [ "modules_install" ];

  meta = {
    description = "mt76 Wi-Fi drivers from the kernel source, with local patches";
    license = lib.licenses.isc;
    platforms = lib.platforms.linux;
  };
}
