{ buildGoModule, diffutils }:

buildGoModule {
  pname = "web-client-html";
  version = "0.1.0";
  src = ./.;
  vendorHash = "sha256-NUbN3Dbhw73jwk7eB/PQnwIJljEp5vI1KazebY43vm4=";
  env.CGO_ENABLED = "0";
  ldflags = [ "-X main.diffCommand=${diffutils}/bin/diff" ];
  meta.mainProgram = "web-client-html";
}
