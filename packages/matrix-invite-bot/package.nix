{
  pkg-config,
  rustPlatform,
  sqlite,
}:

rustPlatform.buildRustPackage {
  pname = "matrix-invite-bot";
  version = "0.1.0";
  src = ./.;
  cargoLock.lockFile = ./Cargo.lock;
  meta.mainProgram = "matrix-invite-bot";
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ sqlite ];
}
