{ buildGoModule, diffutils }:

buildGoModule {
  pname = "web-client-html";
  version = "0.1.0";
  src = ./.;
  vendorHash = "sha256-Y/MrinYTPaUvlCGzTMYKba2Yv+z13T4k6YXFvEl1E5Y=";
  env.CGO_ENABLED = "0";
  ldflags = [ "-X main.diffCommand=${diffutils}/bin/diff" ];
  meta.mainProgram = "web-client-html";
}
