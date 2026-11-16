# The amdgpu driver built out of tree from the kernel's own source, with
# ./patches applied. It installs under updates/, which depmod searches
# before the in-tree kernel/ copy, so it replaces the kernel's amdgpu
# without a kernel rebuild. To try a driver change, add a patch with
# kernel-tree paths (a/drivers/gpu/drm/amd/...), switch, and reboot:
# amdgpu drives the panel, so it cannot be reloaded under a running
# compositor.
#
# Only amdgpu.ko is rebuilt; amdxcp and the shared DRM helpers stay in
# tree, so patches must not change their interfaces. Take kernel and
# kernelModuleMakeFlags from the same kernelPackages.
{
  kernel,
  kernelModuleMakeFlags,
  lib,
  stdenv,
  xz,
}:
let
  # amdgpu's Makefile pulls in ../display, ../pm, ../amdkfd and ../include.
  amdDir = "drivers/gpu/drm/amd";
in
stdenv.mkDerivation {
  pname = "amdgpu";
  inherit (kernel) src version;

  # Only the driver: the kernel's build tree comes from kernel.dev. The
  # tree is renamed to src because its path ends up in a preprocessor
  # #include (see postPatch), where "linux" would expand to 1.
  unpackPhase = ''
    runHook preUnpack
    tar -xf $src --wildcards '*/${amdDir}/*'
    mv linux-* src
    sourceRoot=src
    export AMDGPU_SRC=$PWD/$sourceRoot/${amdDir}/amdgpu
    runHook postUnpack
  '';

  patches = lib.sort (a: b: a < b) (lib.filesystem.listFilesRecursive ./patches);

  # The tracepoint header names itself relative to the kernel's include/
  # (../../drivers/...), which does not exist under kernel.dev.
  postPatch = ''
    substituteInPlace ${amdDir}/amdgpu/amdgpu_trace.h \
      --replace-fail '#define TRACE_INCLUDE_PATH ../../drivers/gpu/drm/amd/amdgpu' \
                     "#define TRACE_INCLUDE_PATH $AMDGPU_SRC"
  '';

  # modules_install compresses the modules as the kernel does (xz).
  nativeBuildInputs = kernel.moduleBuildDependencies ++ [ xz ];

  # Plain mkDerivation runs make serially; this passes -j/-l from NIX_BUILD_CORES.
  enableParallelBuilding = true;

  makeFlags = kernelModuleMakeFlags ++ [
    "-C"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "M=$(AMDGPU_SRC)"
  ];

  buildFlags = [ "modules" ];

  # NixOS runs depmod over all module packages together.
  installFlags = [
    "INSTALL_MOD_PATH=${placeholder "out"}"
    "INSTALL_MOD_DIR=updates/amdgpu"
    # Strip debug info as the in-tree build does: 5 MB instead of 115 MB.
    "INSTALL_MOD_STRIP=1"
    "DEPMOD=true"
  ];
  installTargets = [ "modules_install" ];

  meta = {
    description = "AMD GPU driver from the kernel source, with local patches";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
  };
}
