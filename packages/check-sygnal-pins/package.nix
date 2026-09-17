{ diffutils, rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "check-sygnal-pins";
  version = "0.1.0";
  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;
  env.DIFF = "${diffutils}/bin/diff";
  meta.mainProgram = "check-sygnal-pins";
}
