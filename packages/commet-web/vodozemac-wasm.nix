{
  binaryen,
  buildPackages,
  cargo,
  commet-web,
  flutter,
  flutter_rust_bridge_codegen,
  lib,
  removeReferencesTo,
  runCommand,
  rustc,
  rustPlatform,
  stdenv,
  symlinkJoin,
  wasm-bindgen-cli_0_2_100,
  wasm-pack,
  which,
  writableTmpDirAsHomeHook,
}:

let
  pubSources = commet-web.pubspecLock.dependencySources;
  pubCache = runCommand "commet-vodozemac-pub-cache" { } ''
    mkdir -p "$out/hosted/pub.dev"
    ${lib.concatMapAttrsStringSep "\n" (
      _: package: "ln -s ${package} \"$out/hosted/pub.dev/${lib.removePrefix "pub-" package.name}\""
    ) (lib.filterAttrs (_: package: lib.hasPrefix "pub-" package.name) pubSources)}
  '';

  sysroot = symlinkJoin {
    name = "rustc-unwrapped-with-libsrc";
    paths = [ buildPackages.rustc.unwrapped ];
    postBuild = ''
      mkdir -p "$out/lib/rustlib/src/rust"
      ln -s ${rustPlatform.rustLibSrc} "$out/lib/rustlib/src/rust/library"
    '';
  };
  rustcWithLibSrc = buildPackages.rustc.override { inherit sysroot; };
in
stdenv.mkDerivation {
  pname = "commet-vodozemac-wasm";
  inherit (pubSources.vodozemac) version;

  unpackPhase = ''
    runHook preUnpack
    cp -R ${pubSources.flutter_vodozemac}/rust ./rust
    cp -R ${pubSources.vodozemac} ./dart
    chmod -R u+w .
    runHook postUnpack
  '';

  postPatch = ''
    sed -i '/^dev_dependencies:/,/^$/d' dart/pubspec.yaml
    # Unused by the generated bindings and pulls analyzer versions outside the
    # application lock when dart-vodozemac is prepared as a standalone package.
    sed -i '/^  test_core:/d' dart/pubspec.yaml
  '';

  cargoRoot = "rust";
  cargoDeps = symlinkJoin {
    name = "commet-vodozemac-wasm-cargo-deps";
    paths = [ pubSources.flutter_vodozemac.passthru.cargoDeps ];
    postBuild = ''
      cp -rsn ${rustPlatform.rustVendorSrc}/* "$out"/*/
    '';
  };

  nativeBuildInputs = [
    rustPlatform.cargoSetupHook
    rustcWithLibSrc
    rustc.llvmPackages.lld
    cargo
    flutter
    flutter_rust_bridge_codegen
    which
    wasm-pack
    wasm-bindgen-cli_0_2_100
    binaryen
    writableTmpDirAsHomeHook
    removeReferencesTo
  ];

  buildPhase = ''
    runHook preBuild

    export PUB_CACHE="$TMPDIR/pub-cache"
    mkdir -p "$PUB_CACHE/hosted"
    ln -s ${pubCache}/hosted/pub.dev "$PUB_CACHE/hosted/pub.dev"

    pushd dart
    dart pub get --offline
    popd

    RUST_LOG=info flutter_rust_bridge_codegen build-web \
      --dart-root "$(realpath ./dart)" \
      --rust-root "$(realpath ./rust)" \
      --release

    # flutter_rust_bridge otherwise uses Function() to expose this lexical
    # binding, which requires CSP 'unsafe-eval'. Export it explicitly instead.
    printf '\nglobalThis.wasm_bindgen = wasm_bindgen;\n' \
      >> dart/web/pkg/vodozemac_bindings_dart.js

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp dart/web/pkg/vodozemac_bindings_dart* "$out/"
    runHook postInstall
  '';

  preFixup = ''
    find "$out" -name '*.wasm' -exec remove-references-to -t ${sysroot} {} +
  '';

  env.RUSTC_BOOTSTRAP = 1;

  meta = commet-web.meta;
}
