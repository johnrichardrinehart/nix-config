# Android accessibility service that seeks the playing media while a Fast
# Forward / Rewind key is held (packages/media-seek-android/src). The store
# holds an unsigned APK; `media-seek-android-install` signs it with a key kept
# outside the store, installs it over adb and grants the two permissions it
# needs.
{
  lib,
  stdenvNoCC,
  androidenv,
  android-tools,
  jdk17_headless,
  writeShellApplication,
  zip,
}:
let
  buildToolsVersion = "36.0.0";
  sdk = (androidenv.override { licenseAccepted = true; }).composeAndroidPackages {
    platformVersions = [ "36" ];
    buildToolsVersions = [ buildToolsVersion ];
    includeEmulator = false;
    includeSystemImages = false;
    includeNDK = false;
    includeSources = false;
  };
  sdkRoot = "${sdk.androidsdk}/libexec/android-sdk";
  buildTools = "${sdkRoot}/build-tools/${buildToolsVersion}";
  androidJar = "${sdkRoot}/platforms/android-36/android.jar";
  packageName = "dev.johnrinehart.mediaseek";

  apk = stdenvNoCC.mkDerivation {
    pname = "media-seek-android-apk";
    version = "1";
    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [
        ./AndroidManifest.xml
        ./res
        ./src
      ];
    };
    nativeBuildInputs = [
      jdk17_headless
      zip
    ];
    buildPhase = ''
      runHook preBuild
      ${buildTools}/aapt2 compile --dir res -o res.zip
      ${buildTools}/aapt2 link res.zip -o base.apk -I ${androidJar} \
        --manifest AndroidManifest.xml --min-sdk-version 29 --target-sdk-version 36 \
        --version-code 1 --version-name 1
      mkdir classes dex
      javac --release 17 -classpath ${androidJar} -d classes $(find src -name '*.java')
      ${buildTools}/d8 --release --min-api 29 --lib ${androidJar} --output dex $(find classes -name '*.class')
      (cd dex && zip -X ../base.apk classes.dex)
      ${buildTools}/zipalign -p -f 4 base.apk aligned.apk
      runHook postBuild
    '';
    installPhase = ''
      install -Dm644 aligned.apk $out/media-seek-unsigned.apk
    '';
  };
in
writeShellApplication {
  name = "media-seek-android-install";
  runtimeInputs = [
    android-tools
    jdk17_headless
  ];
  text = ''
    # Usage: media-seek-android-install [adb -s SERIAL options...]
    key_dir="''${XDG_DATA_HOME:-$HOME/.local/share}/media-seek-android"
    keystore="$key_dir/signing.p12"
    if [ ! -e "$keystore" ]; then
      mkdir -p "$key_dir"
      keytool -genkeypair -keystore "$keystore" -storetype PKCS12 -storepass media-seek \
        -alias media-seek -keyalg EC -groupname secp256r1 -validity 36500 \
        -dname "CN=media-seek-android"
    fi
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    ${buildTools}/apksigner sign --ks "$keystore" --ks-pass pass:media-seek \
      --out "$work/media-seek.apk" ${apk}/media-seek-unsigned.apk

    adb "$@" install -r "$work/media-seek.apk"
    adb "$@" shell cmd notification allow_listener ${packageName}/${packageName}.SessionListener
    service=${packageName}/${packageName}.SeekService
    enabled=$(adb "$@" shell settings get secure enabled_accessibility_services | tr -d '\r')
    case ":$enabled:" in
      *":$service:"*) ;;
      ":null:" | "::") adb "$@" shell settings put secure enabled_accessibility_services "$service" ;;
      *) adb "$@" shell settings put secure enabled_accessibility_services "$enabled:$service" ;;
    esac
    adb "$@" shell settings put secure accessibility_enabled 1
  '';
  passthru = { inherit apk; };
  meta = {
    description = "Install the Media Seek accessibility service on an Android phone over adb";
    platforms = [
      "aarch64-darwin"
      "x86_64-darwin"
      "x86_64-linux"
    ];
  };
}
