{
  lib,
  applyPatches,
  fetchFromGitHub,
  onnxruntime,
  openvino,
}:

let
  version = "1.30.0";

  src = fetchFromGitHub {
    owner = "microsoft";
    repo = "onnxruntime";
    tag = "v${version}";
    fetchSubmodules = true;
    hash = "sha256-kU6e9oK77k67vdBVtweuTgraV5L8SmyBzOgCEssaOTs=";
  };

  # Dependencies that differ from nixpkgs' onnxruntime; see
  # https://github.com/microsoft/onnxruntime/blob/v<VERSION>/cmake/deps.txt
  onnx-src = fetchFromGitHub {
    name = "onnx-src";
    owner = "onnx";
    repo = "onnx";
    tag = "v1.22.0";
    hash = "sha256-gc65t/VN3kdvV9tiFoOk6Sw+OZe4Udgm3VcZPP9gzpE=";
  };

  # ORT no longer accepts a system cpuinfo: it builds its pinned revision
  # with its own Linux patches (sysfs fallback and reference-counted
  # cpuinfo_deinitialize), applied here the same way its CMake would.
  cpuinfo-src = applyPatches {
    name = "cpuinfo-src";
    src = fetchFromGitHub {
      owner = "pytorch";
      repo = "cpuinfo";
      rev = "66ee79c038d70dad9f08705b2c9b3e58f6d8f512";
      hash = "sha256-A+kTj3GthwmO2kKeG3gG/zjvvt45OmuEvAtRLzwfEyM=";
    };
    patches = [
      "${src}/cmake/patches/cpuinfo/fix_missing_sysfs_fallback.patch"
      "${src}/cmake/patches/cpuinfo/enable_deinit_refcounting.patch"
    ];
    patchFlags = [
      "-p1"
      "--binary"
      "--ignore-whitespace"
    ];
  };

  # Patches from nixpkgs' onnxruntime that no longer apply: stacktrace.cc now
  # uses absl instead of execinfo, and the core-library Protobuf
  # serialization moved to ep_context_utils.cc; remaining [[nodiscard]]
  # warnings are non-fatal under --compile-no-warning-as-error.
  droppedPatches = [
    "musl-execinfo.patch"
    "protobuf34-nodiscard.patch"
  ];
in
(onnxruntime.override {
  pythonSupport = false;
}).overrideAttrs
  (old: {
    inherit version src;

    patches = lib.filter (patch: !(lib.elem (baseNameOf patch) droppedPatches)) old.patches;

    # The in-tree cpuinfo replaces nixpkgs' cpuinfo, whose older cpuinfo.h
    # must not shadow the pinned one.
    buildInputs = lib.filter (dep: (dep.pname or "") != "cpuinfo") old.buildInputs ++ [ openvino ];
    cmakeFlags =
      map (
        flag:
        if lib.hasPrefix "-DFETCHCONTENT_SOURCE_DIR_ONNX:" flag then
          lib.cmakeFeature "FETCHCONTENT_SOURCE_DIR_ONNX" "${onnx-src}"
        else
          flag
      ) old.cmakeFlags
      ++ [
        "--compile-no-warning-as-error"
        (lib.cmakeFeature "FETCHCONTENT_SOURCE_DIR_PYTORCH_CPUINFO" "${cpuinfo-src}")
        (lib.cmakeBool "onnxruntime_USE_OPENVINO" true)
        (lib.cmakeBool "onnxruntime_DISABLE_RTTI" false)
        (lib.cmakeBool "onnxruntime_BUILD_UNIT_TESTS" false)
        "-DOpenVINO_DIR=${openvino}/runtime/cmake"
      ];
    postFixup = (old.postFixup or "") + ''
      patchelf --add-rpath ${openvino}/runtime/lib/intel64 $out/lib/libonnxruntime_providers_openvino.so
    '';
  })
