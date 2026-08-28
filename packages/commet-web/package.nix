{
  applyPatches,
  callPackage,
  fetchurl,
  fetchzip,
  flutter341,
  jq,
  lib,
  stdenvNoCC,
}:

let
  pins = builtins.fromJSON (builtins.readFile ./pins.json);
  buildVersion = builtins.head (builtins.match "([0-9]+\\.[0-9]+\\.[0-9]+).*" pins.version);
  commetSource = fetchzip {
    url = "https://github.com/commetchat/commet/archive/refs/tags/v${
      lib.replaceStrings [ "+" ] [ "%2B" ] pins.version
    }.tar.gz";
    hash = pins.srcHash;
  };
  notoSansJp = fetchzip {
    url = "https://github.com/notofonts/noto-cjk/releases/download/Sans2.004/16_NotoSansJP.zip";
    hash = "sha256-I/hdMGzusd2yhaVOBCNQPu6IoIpvVi6uIQaz01uzkxs=";
    stripRoot = false;
  };
  fontFallbackPins = lib.importJSON ./font-fallbacks.json;
  fontFallbackSources = map (
    font:
    fetchurl {
      url = "${fontFallbackPins.baseUrl}${font.path}";
      inherit (font) hash;
    }
  ) fontFallbackPins.fonts;
  fontFallbackFiles = lib.zipListsWith (font: source: {
    inherit font source;
  }) fontFallbackPins.fonts fontFallbackSources;
  fontFallbacks =
    assert fontFallbackPins.flutterVersion == flutter341.version;
    assert fontFallbackPins.engineRevision == flutter341.engineVersion;
    assert builtins.length fontFallbackFiles == fontFallbackPins.fontCount;
    assert lib.all (entry: builtins.match "[A-Za-z0-9._/-]+" entry.font.path != null) fontFallbackFiles;
    stdenvNoCC.mkDerivation {
      pname = "flutter-font-fallbacks";
      version = fontFallbackPins.engineRevision;
      dontUnpack = true;
      passAsFile = [ "installCommands" ];
      installCommands = lib.concatMapStringsSep "\n" (entry: ''
        install -Dm444 ${entry.source} "$out/${entry.font.path}"
      '') fontFallbackFiles;

      installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        source "$installCommandsPath"
        cp ${notoSansJp}/LICENSE "$out/OFL.txt"
        cp ${commetSource}/commet/assets/font/roboto/LICENSE.txt \
          "$out/Roboto-LICENSE.txt"
        cp ${./font-fallbacks.json} "$out/INVENTORY.json"
        runHook postInstall
      '';

      disallowedReferences = fontFallbackSources;
    };

  # This recursion is evaluation-only: the Wasm build reuses the Pub sources
  # resolved for Commet, while Commet includes the generated Wasm artifact.
  # Nix laziness prevents a derivation-time dependency cycle.
  commetWeb = flutter341.buildFlutterApplication (finalAttrs: {
    pname = "commet-web";
    version = pins.version;

    # Patch the complete source before Pub resolves local path dependencies;
    # postPatch in the app build cannot modify Tiamat's store-backed package.
    src = applyPatches {
      name = "commet-${finalAttrs.version}-source";
      src = commetSource;
      postPatch = ''
        substituteInPlace commet/pubspec.yaml \
          --replace-fail "    - family: RobotoCustom" "    - family: Roboto"
        substituteInPlace tiamat/pubspec.yaml \
          --replace-fail "    - family: RobotoCustom" "    - family: Roboto"
        substituteInPlace tiamat/lib/config/style/theme_base.dart \
          --replace-fail 'fontFamily: "RobotoCustom"' 'fontFamily: "Roboto"'
        substituteInPlace tiamat/lib/config/style/theme_common.dart \
          --replace-fail \
          'const fonts = ["EmojiFont"];' \
          'const fonts = ["EmojiFont", "Noto Sans JP"];'
        substituteInPlace commet/web/index.html \
          --replace-fail \
          'engineInitializer.initializeEngine().then(function (appRunner) {' \
          'engineInitializer.initializeEngine({ fontFallbackBaseUrl: "/font-fallback/" }).then(function (appRunner) {'
      '';
    };

    strictDeps = true;
    nativeBuildInputs = [ jq ];
    sourceRoot = "${finalAttrs.src.name}/commet";
    packageRoot = "commet";
    targetFlutterPlatform = "web";

    pubspecLockFilePath = "../pubspec.lock";
    pubspecLock = lib.importJSON ./pubspec.lock.json;
    gitHashes = lib.importJSON ./git-hashes.json;

    customSourceBuilders.flutter_rust_bridge =
      { src, version, ... }:
      stdenvNoCC.mkDerivation {
        pname = "pub-flutter_rust_bridge";
        inherit version src;
        inherit (src) passthru;

        postPatch = ''
          substituteInPlace lib/src/wasm_module/_web.dart \
            --replace-fail "  jsEval('window.wasm_bindgen = wasm_bindgen');" \
            "  // wasm_bindgen is exported by the generated glue without eval."
        '';

        installPhase = ''
          runHook preInstall
          cp -R . "$out"
          runHook postInstall
        '';
      };

    patches = [ ./fix-hardcoded-flutter-cmd.patch ];

    postPatch = ''
      noto_font_definition=$(cat <<'EOF'
          - family: Noto Sans JP
            fonts:
              - asset: assets/font/noto-sans-jp/NotoSansJP-Regular.otf
              - asset: assets/font/noto-sans-jp/NotoSansJP-Bold.otf
                weight: 700

          - family: Code
      EOF
      )
      substituteInPlace pubspec.yaml \
        --replace-fail "    - family: Code" "$noto_font_definition"
    '';

    env.COMMET_PROD = 1;
    flutterBuildFlags = [
      "--build-name=${buildVersion}"
      "--dart-define=BUILD_MODE=release"
      "--dart-define=PLATFORM=web"
      "--dart-define=GIT_HASH=v${finalAttrs.version}"
      "--dart-define=VERSION_TAG=v${finalAttrs.version}"
      "--dart-define=ENABLE_GOOGLE_SERVICES=false"
      "--dart-define=BUILD_DATE=${pins.buildDate}"
      "--dart-define=FLUTTER_WEB_CANVASKIT_URL=canvaskit/"
    ];

    preBuild = ''
      packageRun intl_utils -e generate
      dart run --packages=.dart_tool/package_config.json scripts/codegen.dart
      packageRun intl_translation -e generate_from_arb \
        --sources-list-file "$PWD/lib/generated/l10n/sources_list_file.txt" \
        --translations-list-file "$PWD/lib/generated/l10n/arb_list_file.txt" \
        --output-dir=lib/generated/l10n
      packageRun build_runner build --delete-conflicting-outputs

      mkdir -p assets/font/noto-sans-jp assets/vodozemac
      cp ${notoSansJp}/NotoSansJP-Regular.otf assets/font/noto-sans-jp/
      cp ${notoSansJp}/NotoSansJP-Bold.otf assets/font/noto-sans-jp/
      cp ${notoSansJp}/LICENSE assets/font/noto-sans-jp/OFL.txt
      cp -R ${vodozemacWasm}/* assets/vodozemac/
    '';

    postBuild = ''
      # Flutter generates this identifier randomly even when all inputs are
      # fixed. Normalize it so the output and inline CSP hash are reproducible.
      for file in build/web/index.html build/web/flutter_bootstrap.js; do
        sed -E -i \
          "s#\"[0-9]+\" /\\* Flutter's service worker is deprecated#\"${pins.buildDate}\" /* Flutter's service worker is deprecated#" \
          "$file"
      done
      rm -f build/web/.last_build_id
      cp -R ${fontFallbacks} build/web/font-fallback
    '';

    postInstall = ''
      grep -Fq 'globalThis.wasm_bindgen = wasm_bindgen;' \
        "$out/assets/assets/vodozemac/vodozemac_bindings_dart.js"
      if grep -Fq 'window.wasm_bindgen = wasm_bindgen' "$out/main.dart.js"; then
        echo 'flutter_rust_bridge still requires unsafe-eval' >&2
        exit 1
      fi
      font_manifest="$out/assets/FontManifest.json"
      jq -e '
        . as $manifest
        | def has_fonts($family; $assets):
            [$manifest[] | select(.family == $family) | .fonts[].asset]
            | contains($assets);
          has_fonts("Noto Sans JP"; [
            "assets/font/noto-sans-jp/NotoSansJP-Regular.otf",
            "assets/font/noto-sans-jp/NotoSansJP-Bold.otf"
          ])
          and has_fonts("Roboto"; [
            "assets/font/roboto/Roboto-Regular.ttf",
            "assets/font/roboto/Roboto-Bold.ttf"
          ])
          and has_fonts("packages/tiamat/Roboto"; [
            "packages/tiamat/assets/font/roboto/Roboto-Regular.ttf",
            "packages/tiamat/assets/font/roboto/Roboto-Bold.ttf"
          ])
          and all($manifest[]; .family != "NotoSansJP")
          and all($manifest[]; (.family | contains("RobotoCustom") | not))
      ' "$font_manifest"

      if grep -Fq 'NotoSansJP' "$out/main.dart.js" \
        || grep -Fq 'RobotoCustom' "$out/main.dart.js"; then
        echo 'stale mismatched bundled font family name in web output' >&2
        exit 1
      fi
      grep -Fq 'Noto Sans JP' "$out/main.dart.js"
      grep -Fq 'Roboto' "$out/main.dart.js"
      grep -Fq 'fontFallbackBaseUrl: "/font-fallback/"' "$out/index.html"
      test "$(find "$out/font-fallback" -type f -name '*.woff2' | wc -l)" -eq ${toString fontFallbackPins.fontCount}
      test -f "$out/font-fallback/OFL.txt"
      test -f "$out/font-fallback/Roboto-LICENSE.txt"
      test -f "$out/font-fallback/INVENTORY.json"
    '';

    passthru = {
      inherit vodozemacWasm;
    };

    meta = {
      description = "Web build of the Commet Matrix client";
      homepage = "https://commet.chat";
      changelog = "https://github.com/commetchat/commet/releases/tag/v${
        lib.replaceStrings [ "+" ] [ "%2B" ] finalAttrs.version
      }";
      license = [
        lib.licenses.agpl3Only
        lib.licenses.asl20
        lib.licenses.ofl
      ];
      platforms = lib.platforms.linux;
    };
  });

  vodozemacWasm = callPackage ./vodozemac-wasm.nix {
    commet-web = commetWeb;
    flutter = flutter341;
  };
in
commetWeb
