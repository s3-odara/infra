{
  bash,
  beam_minimal,
  coreutils,
  fetchFromGitHub,
  gawk,
  gnugrep,
  gnused,
  lib,
  libyaml,
  makeWrapper,
  openssl,
}:

let
  beamPackages = beam_minimal.packages.erlang;
  inherit (beamPackages) fetchRebar3Deps rebar3Relx;
  pins = builtins.fromJSON (builtins.readFile ./pins.json);

  src = fetchFromGitHub {
    owner = "processone";
    repo = "eturnal";
    # Upstream does not sign this release tag; the updater trusts the official
    # processone repository, resolves the tag once, and pins that commit.
    rev = pins.commit;
    hash = pins.srcHash;
  };
in
rebar3Relx {
  pname = "eturnal";
  version = pins.version;
  inherit src;
  releaseType = "release";

  checkouts = fetchRebar3Deps {
    name = "eturnal-deps";
    version = pins.version;
    inherit src;
    sha256 = pins.depsHash;
  };

  buildPlugins = [ beamPackages.pc ];
  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [
    openssl
    libyaml
  ];

  postPatch = ''
    patchShebangs .
    grep -q 'eturnal_prefix' build.config
    sed -i 's|{eturnal_prefix,.*}\.|{eturnal_prefix, "'"$out"'"}.|' build.config
  '';

  # rebar3Relx overrides postInstall, so wrap the release in postFixup.
  postFixup =
    let
      runtimePath = lib.makeBinPath [
        beamPackages.erlang
        bash
        coreutils
        gnused
        gnugrep
        gawk
      ];
    in
    ''
      wrapProgram $out/rel/eturnal/bin/eturnalctl \
        --prefix PATH : ${runtimePath} \
        --run 'export RUNTIME_DIRECTORY="''${RUNTIME_DIRECTORY:-''${XDG_RUNTIME_DIR:-/tmp}/eturnal}"'
      wrapProgram $out/rel/eturnal/bin/eturnal \
        --prefix PATH : ${runtimePath} \
        --run 'export RUNTIME_DIRECTORY="''${RUNTIME_DIRECTORY:-''${XDG_RUNTIME_DIR:-/tmp}/eturnal}"'
    '';

  meta = {
    description = "STUN and TURN server for VoIP and WebRTC";
    homepage = "https://eturnal.net";
    changelog = "https://github.com/processone/eturnal/releases/tag/${pins.version}";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
    mainProgram = "eturnalctl";
  };
}
