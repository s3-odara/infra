{
  pkg-config,
  rustPlatform,
  sqlite,
}:

rustPlatform.buildRustPackage {
  pname = "matrix-bot";
  version = "0.1.0";
  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;
  meta.mainProgram = "matrix-bot";
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ sqlite ];
}
