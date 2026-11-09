{
  aws-lc,
  cacert,
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
  buildInputs = [
    aws-lc
    sqlite
  ];
  # reqwest loads system roots when constructing even an HTTP-only test client.
  nativeCheckInputs = [ cacert ];
}
