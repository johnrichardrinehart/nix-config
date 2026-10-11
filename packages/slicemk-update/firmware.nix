{
  lib,
  stdenv,
  fetchzip,
  cmake,
  ninja,
  dtc,
  gperf,
  git,
  protobuf,
  python3,
  gcc-arm-embedded-13,
  config ? ./keyboard.json,
  keymap ? null,
  conf ? null,
  board ? "slicemk_ergodox_202207_green_left",
  shield ? "slicemk_ergodox_leftcentral",
  hostBluetoothPatch ? ./host-bluetooth.patch,
}:
let
  sourceRevision = "71f8242b8ab2e9f9c86ebbb221ba15876413f295";
  # app/west.yml names a branch, so freeze its resolved commit too.
  zephyrRevision = "dacab4875df72109b96cc8977547a0dc04875bcd";
  githubSource =
    owner: repo: rev: hash:
    fetchzip {
      url = "https://codeload.github.com/${owner}/${repo}/tar.gz/${rev}";
      inherit hash;
      extension = "tar.gz";
    };
  source =
    githubSource "slicemk" "zmk" sourceRevision
      "sha256-9yE0egEJG+lfHMyadQb6dhmlLPaa/EWokbCThi9ZO4A=";
  zephyr =
    githubSource "zmkfirmware" "zephyr" zephyrRevision
      "sha256-7QpHcotCG+m16PvGdB+aZrU+5p/FSXhmkmtMoUkKqs4=";

  # Hardware modules imported by app/west.yml from Zephyr's west.yml,
  # plus the two direct ZMK dependencies. BabbleSim's disabled test-only
  # group is not needed for either physical target.
  modulePins = [
    {
      name = "cmsis";
      owner = "zephyrproject-rtos";
      rev = "5a00331455dd74e31e80efa383a489faea0590e3";
      hash = "sha256-1oCeT681nFDbCyhp0mErktuoj3YtFDzP5dLYdWz0+AM=";
    }
    {
      name = "hal_nordic";
      owner = "zephyrproject-rtos";
      rev = "884c4d61746bc35fbd379c169fc87ddb56c6461d";
      hash = "sha256-L6jCDtBfE78JZDo81VCvdJxFWMoj7EJYzXMAhgqyJ9Q=";
    }
    {
      name = "hal_rpi_pico";
      owner = "zephyrproject-rtos";
      rev = "fba7162cc7bee06d0149622bbcaac4e41062d368";
      hash = "sha256-oJQPq//mAxAQW8QzxixbiHJsMMANtQl3BevMUL9Kv5g=";
    }
    {
      name = "lvgl";
      owner = "zephyrproject-rtos";
      rev = "8a6a2d1d29d17d1e4bdc94c243c146a39d635fdd";
      hash = "sha256-RDirbdNZ0QQ1g0WJyWx2k70J+zUhTdWiF484VAakVWc=";
    }
    {
      name = "segger";
      owner = "zephyrproject-rtos";
      rev = "9d0191285956cef43daf411edc2f1a7788346def";
      hash = "sha256-9nt0z674ubxxvIANPMf82Qf7KsOwR3Hg8wYAK5r/i4c=";
    }
    {
      name = "tinycrypt";
      owner = "zephyrproject-rtos";
      rev = "3e9a49d2672ec01435ffbf0d788db6d95ef28de0";
      hash = "sha256-5gtZbZNx+D/EUkyYk7rPtcxBZaNs4IFGTP/7IXzCoqU=";
    }
    {
      name = "zcbor";
      owner = "zephyrproject-rtos";
      rev = "67fd8bb88d3136738661fa8bb5f9989103f4599e";
      hash = "sha256-Z4I14nLsER+GcqGzd8ILuk9QBUOV3u3aMA4q2s9EI5g=";
    }
    {
      name = "nanopb";
      owner = "zmkfirmware";
      rev = "8c60555d6277a0360c876bd85d491fc4fb0cd74a";
      hash = "sha256-L+BBhQX/oRscA/J7muAmJ/9gr+BE8/Vd7efBzQ7B5/A=";
    }
    {
      name = "zmk-studio-messages";
      owner = "zmkfirmware";
      rev = "6cb4c283e76209d59c45fbcb218800cd19e9339d";
      hash = "sha256-Cfw1htCp3xZt1R+X3kW3e9shEcMGbeBbEqpDoyLJV3s=";
    }
  ];
  modules = map (pin: {
    inherit (pin) name;
    source = githubSource pin.owner pin.name pin.rev pin.hash;
  }) modulePins;
  python = python3.withPackages (
    ps: with ps; [
      anytree
      intelhex
      packaging
      protobuf
      pyelftools
      pykwalify
      pyyaml
      west
    ]
  );
  provenance = builtins.toFile "slicemk-firmware-sources.json" (
    builtins.toJSON {
      inherit
        sourceRevision
        zephyrRevision
        board
        shield
        modulePins
        ;
      toolchain = "gcc-arm-embedded-${gcc-arm-embedded-13.version}";
    }
  );
in
assert lib.assertMsg (
  keymap != null || config != null
) "SliceMK firmware needs either a keymap path or a configurator JSON path";
stdenv.mkDerivation {
  pname = "slicemk-firmware-${board}-${shield}";
  version = "20251223-${builtins.substring 0 7 sourceRevision}";
  src = source;
  patches = [ hostBluetoothPatch ];

  nativeBuildInputs = [
    cmake
    ninja
    dtc
    gperf
    git
    protobuf
    python
    gcc-arm-embedded-13
  ];

  # Zephyr supports a standalone cross compiler; Nixpkgs already packages
  # the complete Arm GNU toolchain, including its multilib/newlib libraries.
  ZEPHYR_TOOLCHAIN_VARIANT = "cross-compile";
  CROSS_COMPILE = "${gcc-arm-embedded-13}/bin/arm-none-eabi-";
  ZEPHYR_BASE = "${zephyr}";
  PYTHONDONTWRITEBYTECODE = "1";

  # Do not let Nix's generic CMake hook choose a host compiler or run a
  # configure phase from the repository root instead of the ZMK application.
  dontUseCmakeConfigure = true;
  dontUseNinjaBuild = true;
  dontUseNinjaInstall = true;
  dontFixCmake = true;
  dontStrip = true;
  dontPatchELF = true;

  configurePhase = ''
    runHook preConfigure
    export HOME="$TMPDIR/home"
    export XDG_CACHE_HOME="$TMPDIR/cache"
    mkdir -p "$HOME" "$XDG_CACHE_HOME" generated-config generated-modules
    ${lib.concatMapStringsSep "\n" (
      module: "ln -s ${module.source} generated-modules/${module.name}"
    ) modules}

    ${
      if keymap != null then
        ''
          cp ${lib.escapeShellArg "${keymap}"} generated-config/slicemk_ergodox.keymap
        ''
      else
        ''
          ${python}/bin/python ${./render-keymap.py} ${lib.escapeShellArg "${config}"} \
            > generated-config/slicemk_ergodox.keymap
        ''
    }

    ${lib.optionalString (config != null) ''
        ${python}/bin/python - ${lib.escapeShellArg "${config}"} <<'PY'
      import json
      import sys
      from pathlib import Path

      settings = json.loads(Path(sys.argv[1]).read_text())["Kconfig"]
      with Path("generated-config/default.conf").open("w") as output:
          for name, value in settings.items():
              if isinstance(value, bool):
                  value = "y" if value else "n"
              output.write(f"{name}={value}\n")
      PY
    ''}
    ${lib.optionalString (config == null) ''
      touch generated-config/default.conf
    ''}
    ${lib.optionalString (shield == "slicemk_ergodox_leftcentral") ''
      # The native soft_off userbutton behavior requires PM support.
      printf '%s\n' 'CONFIG_ZMK_PM_SOFT_OFF=y' >> generated-config/default.conf
    ''}
    ${lib.optionalString (conf != null) ''
      cat ${lib.escapeShellArg "${conf}"} >> generated-config/default.conf
    ''}

    cmake -S app -B build -G Ninja \
      -DBOARD=${lib.escapeShellArg board} \
      -DSHIELD=${lib.escapeShellArg shield} \
      -DZephyr_DIR=${zephyr}/share/zephyr-package/cmake \
      -DZMK_CONFIG="$PWD/generated-config" \
      -DKEYMAP_FILE="$PWD/generated-config/slicemk_ergodox.keymap" \
      -DZEPHYR_MODULES="${
        lib.concatStringsSep ";" (map (module: "$PWD/generated-modules/${module.name}") modules)
      }" \
      -DPYTHON_EXECUTABLE=${python}/bin/python \
      -DBUILD_VERSION=${sourceRevision} \
      -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    cmake --build build --parallel "$NIX_BUILD_CORES"
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/config"
    cp build/zephyr/zmk.uf2 "$out/zmk.uf2"
    cp build/zephyr/zmk.elf "$out/zmk.elf"
    cp build/zephyr/zmk.bin "$out/zmk.bin"
    cp build/zephyr/.config "$out/config/zephyr.config"
    cp build/zephyr/zephyr.dts "$out/config/zephyr.dts"
    cp generated-config/* "$out/config/"
    cp ${provenance} "$out/config/sources.json"
    ${lib.optionalString (config != null) ''
      cp ${lib.escapeShellArg "${config}"} "$out/config/keymap.json"
    ''}
    runHook postInstall
  '';

  passthru = {
    inherit
      sourceRevision
      zephyrRevision
      modulePins
      board
      shield
      ;
  };

  meta = {
    description = "Offline custom SliceMK ZMK firmware with host-only Bluetooth controls";
    homepage = "https://github.com/slicemk/zmk";
    license = lib.licenses.mit;
    platforms = gcc-arm-embedded-13.meta.platforms;
  };
}
