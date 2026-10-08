# moonshine-voice Python package using our custom libmoonshine.so
# built with OpenVINO GPU support.
#
# Built from the upstream source tree rather than the PyPI wheel: the wheel is
# just these pure-Python ctypes bindings plus a bundled libmoonshine.so and
# libonnxruntime, both of which we replace, and PyPI lags the GitHub releases.
{
  lib,
  python3,
  fetchFromGitHub,
  libmoonshine,
}:
python3.pkgs.buildPythonPackage {
  pname = "moonshine-voice";
  # The bindings load libmoonshine through its C ABI, so keep them in lockstep.
  inherit (libmoonshine) version;
  pyproject = true;

  src = fetchFromGitHub {
    owner = "moonshine-ai";
    repo = "moonshine";
    tag = "v${libmoonshine.version}";
    sparseCheckout = [ "language-bindings/python" ];
    hash = "sha256-SgqRQYdIot8aXLdfri6KZvGShV6YBylVI8mt00NBSjk=";
  };

  sourceRoot = "source/language-bindings/python";

  build-system = with python3.pkgs; [
    setuptools
    wheel
  ];

  dependencies = with python3.pkgs; [
    numpy
    sounddevice
    requests
    tqdm
    filelock
    platformdirs
    google-crc32c
  ];

  # Performance: _parse_transcript runs on every update_transcription (~10/s)
  # and rebuilds every accumulated line. Per line it copies the raw audio
  # samples out of C one element at a time via ctypes (audio_data =
  # list(audio_array)) plus per-word timing structs. That cost grows with the
  # transcript, so a long session falls behind real time and dictation lags.
  # Our consumer reads only line.text and the boolean flags, so skip both
  # copies (audio_data and words stay None).
  postPatch = ''
    substituteInPlace src/moonshine_voice/transcriber.py \
      --replace-fail \
        'if line_c.audio_data and line_c.audio_data_count > 0:' \
        'if False:  # JohnOS: skip unused audio_data copy (O(samples)/line/update)' \
      --replace-fail \
        'if line_c.words and line_c.word_count > 0:' \
        'if False:  # JohnOS: skip unused per-word timing copy'
  '';

  # moonshine_api.py loads libmoonshine.so from the package directory first;
  # point it at our OpenVINO-enabled build (which carries its own ORT rpath).
  postInstall = ''
    ln -s ${libmoonshine}/lib/libmoonshine.so $out/${python3.sitePackages}/moonshine_voice/libmoonshine.so
  '';

  pythonImportsCheck = [ "moonshine_voice" ];

  meta = {
    description = "Fast, accurate, on-device AI voice library with OpenVINO GPU support";
    homepage = "https://moonshine.ai";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
  };
}
