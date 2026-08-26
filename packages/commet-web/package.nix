{
  fetchurl,
  lib,
  stdenvNoCC,
}:

let
  pins = builtins.fromJSON (builtins.readFile ./pins.json);
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "commet-web";
  version = pins.version;

  src = fetchurl {
    url = "https://github.com/commetchat/commet/releases/download/v${
      lib.replaceStrings [ "+" ] [ "%2B" ] finalAttrs.version
    }/commet-web.tar.gz";
    hash = pins.srcHash;
  };

  sourceRoot = "web";

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -R . "$out/"
    runHook postInstall
  '';

  meta = {
    description = "Web build of the Commet Matrix client";
    homepage = "https://commet.chat";
    changelog = "https://github.com/commetchat/commet/releases/tag/v${
      lib.replaceStrings [ "+" ] [ "%2B" ] finalAttrs.version
    }";
    license = lib.licenses.agpl3Only;
    platforms = lib.platforms.all;
  };
})
