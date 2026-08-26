{
  fetchurl,
  lib,
  stdenvNoCC,
}:

let
  pins = builtins.fromJSON (builtins.readFile ./pins.json);
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "conversejs";
  version = pins.version;

  src = fetchurl {
    url = "https://github.com/conversejs/converse.js/releases/download/v${finalAttrs.version}/converse.js-${finalAttrs.version}.tgz";
    hash = pins.srcHash;
  };

  sourceRoot = "package";

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -R dist/. "$out/"
    runHook postInstall
  '';

  meta = {
    description = "Web-based XMPP client";
    homepage = "https://conversejs.org";
    changelog = "https://github.com/conversejs/converse.js/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mpl20;
    platforms = lib.platforms.all;
  };
})
