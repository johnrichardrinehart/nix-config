# Cross-compiled siraben/psi coding agent using curl with mbedTLS to keep the
# runtime closure small and free of OpenSSL.
{
  argtable,
  buildPackages,
  cacert,
  cjson,
  curl,
  gnumake,
  lib,
  libedit,
  lua5_5,
  mbedtls,
  pkg-config,
  psiSrc,
  stdenv,
  zlib,
}:
let
  isCross = stdenv.buildPlatform != stdenv.hostPlatform;

  mbedtlsLibOnly = mbedtls.overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [
      "-DENABLE_PROGRAMS=OFF"
      "-DENABLE_TESTING=OFF"
    ];
    postConfigure = "";
  });

  curlWithMbedtls =
    (curl.override {
      brotliSupport = false;
      http2Support = false;
      opensslSupport = false;
      idnSupport = false;
      http3Support = false;
      pslSupport = false;
      scpSupport = false;
      gssSupport = false;
      zstdSupport = false;
    }).overrideAttrs
      (old: {
        configureFlags = (lib.remove "--without-ssl" old.configureFlags) ++ [
          "--with-mbedtls=${lib.getDev mbedtlsLibOnly}"
          "--with-ca-bundle=${cacert}/etc/ssl/certs/ca-bundle.crt"
        ];
        propagatedBuildInputs = old.propagatedBuildInputs ++ [ mbedtlsLibOnly ];
        nativeCheckInputs = lib.filter (x: (lib.getName x) != "openssl") (old.nativeCheckInputs or [ ]);
        # Drop the wcurl shell script so curl.bin does not pull bash into the image.
        postInstall = (old.postInstall or "") + ''
          rm -f "''${!outputBin}/bin/wcurl"
        '';
      });
in
stdenv.mkDerivation {
  pname = "psi";
  version = "0.2.0";
  src = psiSrc;

  nativeBuildInputs = [
    gnumake
    pkg-config
  ];

  # Build-platform compiler and zlib for the Lua bytecode embed helper.
  depsBuildBuild = [
    buildPackages.stdenv.cc
  ]
  ++ lib.optionals isCross [ buildPackages.zlib ];

  buildInputs = [
    argtable
    cjson
    curlWithMbedtls
    libedit
    lua5_5
    zlib
  ];

  enableParallelBuilding = true;
  strictDeps = true;

  makeFlags = [
    "CC=${stdenv.cc.targetPrefix}cc"
    "HOST_CC=${buildPackages.stdenv.cc}/bin/cc"
    "PKG_CONFIG=${stdenv.cc.targetPrefix}pkg-config"
    "CA_BUNDLE_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
    "LUA_BOOT_FILE=$(out)/share/psi/boot.lua"
  ];

  installFlags = [ "PREFIX=$(out)" ];
  stripAllList = [ "bin" ];

  preBuild = lib.optionalString isCross ''
    makeFlagsArray+=(
      "HOST_CFLAGS_ZLIB=-I${buildPackages.zlib.dev}/include"
      "HOST_LIBS_ZLIB=-L${buildPackages.zlib.out}/lib -lz"
    )
  '';

  passthru = {
    curl = curlWithMbedtls;
  };

  meta = {
    description = "Minimal C and Lua coding agent";
    homepage = "https://github.com/siraben/psi";
    license = lib.licenses.mit;
    mainProgram = "psi";
  };
}
