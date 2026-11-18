{ buildGoModule }:

buildGoModule {
  pname = "web-client-html";
  version = "0.1.0";
  src = ./.;
  vendorHash = "sha256-GZk22vwgT7fvjY5PDRKaWW8Y9UO2IL+MqSKKgrhguxQ=";
  env.CGO_ENABLED = "0";
  meta.mainProgram = "web-client-html";
}
