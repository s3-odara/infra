{
  dockerTools,
  gnutar,
  jq,
  lib,
  stdenvNoCC,
}:

let
  pins = builtins.fromJSON (builtins.readFile ./pins.json);
  image = dockerTools.pullImage {
    imageName = "ghcr.io/sableclient/sable";
    imageDigest = pins.imageDigest;
    hash = pins.imageHash;
    finalImageTag = pins.version;
    os = "linux";
    arch = "amd64";
  };
in
stdenvNoCC.mkDerivation {
  pname = "sable";
  version = pins.version;
  dontUnpack = true;

  nativeBuildInputs = [
    gnutar
    jq
  ];

  installPhase = ''
    runHook preInstall

    mkdir image root "$out"
    tar -xf ${image} -C image
    while IFS= read -r layer; do
      layer_entries=$(tar -tf "image/$layer")
      if grep -Eq '(^|/)\.wh\.' <<<"$layer_entries"; then
        echo "Sable image contains unsupported OCI whiteouts" >&2
        exit 1
      fi
      tar -xf "image/$layer" -C root
    done < <(jq -r '.[0].Layers[]' image/manifest.json)
    cp -a root/app/. "$out/"

    runHook postInstall
  '';

  meta = {
    description = "Matrix client based on Cinny";
    homepage = "https://sable.moe";
    changelog = "https://github.com/SableClient/Sable/releases/tag/v${pins.version}";
    license = lib.licenses.agpl3Only;
    platforms = [ "x86_64-linux" ];
  };
}
