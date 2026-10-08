{
  fetchurl,
  lib,
  stdenvNoCC,
  baseUrl ? "https://download.moonshine.ai/model/medium-streaming-en/quantized_26_08_21",
  componentHashes ? {
    "adapter.ort" = "sha256-Pyoofe9XzAlDZ6Duw8T1/DajLsQg6GdktpaSCZGyAoE=";
    "cross_kv.ort" = "sha256-ZC9uIc0wW+eTQiB8b55raB1GnVW8SMcrJ7hIRvtx/R4=";
    "decoder_kv.ort" = "sha256-GTuzZkkrdPxK0zjGd46NjrkWqqEbWqJk+QV/Tbd1lIY=";
    "decoder_kv_with_attention.ort" = "sha256-td5LVjm0FV+3lWFh5DGW6yeibbKT8RwdJF7/r2tzgRg=";
    "encoder.ort" = "sha256-EpFeduusfdKHxepjll0GEDpTuhziQqSjTzGPOVjGDDc=";
    "frontend.model.ort" = "sha256-lXaIVccMglHu7MBf7faZmdobirFvYFyfRX/TNUsK1rU=";
    "frontend.weights.ort" = "sha256-WslB9JDL4DWzNbmaQUzDk9YtTG+fJCNJWyhocNJx1wk=";
    "streaming_config.json" = "sha256-KOg7eijpFHJpKgNeDa4xFkIq5DrrK+9e2CLETOibiK8=";
    "tokenizer.bin" = "sha256-aISzX9Y3fUxNMjNqC8FS82tk0eRbZQNoPNwjglCoRy0=";
  },
  modelArch ? 5,
  modelArchName ? "medium-streaming",
  modelName ? "medium-streaming-en",
}:

let
  modelArchMap = {
    tiny = 0;
    base = 1;
    "tiny-streaming" = 2;
    "base-streaming" = 3;
    "small-streaming" = 4;
    "medium-streaming" = 5;
  };

  fetchComponent =
    name: hash:
    fetchurl {
      inherit name hash;
      url = "${baseUrl}/${name}";
    };

  components = lib.mapAttrs fetchComponent componentHashes;
in
stdenvNoCC.mkDerivation {
  pname = "moonshine-models-source";
  version = "0.1.6";

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
  ''
  + lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: component: ''cp ${component} "$out/${name}"'') components
  )
  + ''

    runHook postInstall
  '';

  passthru = {
    inherit
      modelArch
      modelArchMap
      modelArchName
      modelName
      ;
  };

  meta = with lib; {
    description = "Moonshine medium streaming English quantized model components";
    homepage = "https://moonshine.ai";
    license = licenses.unfreeRedistributable;
    platforms = [ "x86_64-linux" ];
  };
}
