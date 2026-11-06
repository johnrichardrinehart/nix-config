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
  board ? "slicemk_ergodox_202207_green_left//zmk",
  shield ? "slicemk_ergodox_leftcentral",
  # Zephyr snippets, e.g. "zmk-usb-logging" (serial log on the USB port).
  snippets ? [ ],
}:
let
  sourceRevision = "cb63068a27f26f9ba58ae926b2430d1a85d3cb23";
  # app/west.yml names a branch, so freeze its resolved commit too.
  zephyrRevision = "10ba6d0cb38bc3d258775d27982f707599320085";
  githubSource =
    owner: repo: rev: hash:
    fetchzip {
      url = "https://codeload.github.com/${owner}/${repo}/tar.gz/${rev}";
      inherit hash;
      extension = "tar.gz";
    };
  source =
    githubSource "johnrichardrinehart" "zmk" sourceRevision
      "sha256-D3hNdmxqGqNmBUmuIJAODuEVyMH6gJ50N3f8mAWaLlQ=";
  zephyr =
    githubSource "zmkfirmware" "zephyr" zephyrRevision
      "sha256-c9gPM6K/RYZzsS1aIIjrgQNMlEFy10DjCYKzvVbkTmg=";

  # Modules allowed by app/west.yml from Zephyr's west.yml (including its
  # optional submanifest), plus the direct ZMK dependencies. BabbleSim's
  # test-only modules are not needed for either physical target.
  modulePins = [
    {
      name = "cmsis";
      owner = "zephyrproject-rtos";
      rev = "d1b8b20b6278615b00e136374540eb1c00dcabe7";
      hash = "sha256-41c6ugwL9D5aQHh6lLCTf2iJP0yAn8bVXOsVUsguuQg=";
    }
    {
      name = "hal_nordic";
      owner = "zephyrproject-rtos";
      rev = "37ca068d7b013fb65a2acc9306bffa48a3e72839";
      hash = "sha256-2Johs7F9W4tspOT+6fRz1kNFN+SKSjaWx2i9tl10Hlw=";
    }
    {
      name = "hal_rpi_pico";
      owner = "zephyrproject-rtos";
      rev = "7b57b24588797e6e7bf18b6bda168e6b96374264";
      hash = "sha256-jpEq/h/ec3cCH0ZZK4OTs+zx9V+g4Sg05HF5uDbwmI8=";
    }
    {
      name = "mbedtls";
      owner = "zephyrproject-rtos";
      rev = "4952e1328529ee549d412b498ea71c54f30aa3b1";
      hash = "sha256-kiB6ZxMLAEJSxQNRaWj+ggMYmk/QqkHsxCN6YbvPSC8=";
    }
    {
      name = "nanopb";
      owner = "zephyrproject-rtos";
      rev = "7307ce399b81ddcb3c3a5dc862c52d4754328d38";
      hash = "sha256-v06q2v1ifISPvO+0Elqa4N1q4/oxnG7C6lTj72Y2uZY=";
    }
    {
      name = "segger";
      owner = "zephyrproject-rtos";
      rev = "cf56b1d9c80f81a26e2ac5727c9cf177116a4692";
      hash = "sha256-RiQm92YGm+pZPLDcZxI9brNfIerumduLFNi6JKGj99E=";
    }
    {
      name = "tinycrypt";
      owner = "zephyrproject-rtos";
      rev = "1012a3ebee18c15ede5efc8332ee2fc37817670f";
      hash = "sha256-JQmkN+ircGU5Ald1+Q4lysuxhZLg2mJpNQ92+agMoCQ=";
    }
    {
      name = "zcbor";
      owner = "zephyrproject-rtos";
      rev = "9b07780aca6fb21f82a241ba386ad9b379809337";
      hash = "sha256-PIxfJfj0WztvsBZPTybkyQ+XImU8b83UtYQwt02CVuc=";
    }
    {
      name = "lvgl";
      owner = "zmkfirmware";
      rev = "f1db87ee98f1810328a8419572fa42a3b5f352ae";
      hash = "sha256-4cIQLNHZ8tLUbDg3BX+RopVEg2YBwE13R7J387mUCzM=";
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
  pname = "slicemk-firmware-${lib.strings.sanitizeDerivationName board}-${shield}";
  version = "20261106-${builtins.substring 0 7 sourceRevision}";
  src = source;

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
    # Zephyr caches compiler checks under the user cache directory. On macOS it
    # looks for ~/Library/Caches, which the build's $HOME lacks, and then falls
    # back to its own read-only source tree, so name the directory outright.
    mkdir -p "$HOME" "$XDG_CACHE_HOME/zephyr" generated-config generated-modules
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
      ${lib.optionalString (
        snippets != [ ]
      ) "-DSNIPPET=${lib.escapeShellArg (lib.concatStringsSep ";" snippets)} \\"}
      -DZephyr_DIR=${zephyr}/share/zephyr-package/cmake \
      -DZMK_CONFIG="$PWD/generated-config" \
      -DKEYMAP_FILE="$PWD/generated-config/slicemk_ergodox.keymap" \
      -DZEPHYR_MODULES="${
        lib.concatStringsSep ";" (map (module: "$PWD/generated-modules/${module.name}") modules)
      }" \
      -DPYTHON_EXECUTABLE=${python}/bin/python \
      -DUSER_CACHE_DIR="$XDG_CACHE_HOME/zephyr" \
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
    homepage = "https://github.com/johnrichardrinehart/zmk";
    license = lib.licenses.mit;
    platforms = gcc-arm-embedded-13.meta.platforms;
  };
}
