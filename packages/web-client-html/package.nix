{ buildGoModule, diffutils }:

buildGoModule {
  pname = "web-client-html";
  version = "0.1.0";
  src = ./.;
  vendorHash = "sha256-GjP9qnP7Se93iGn54nscrHcYx7EFz3YDzzL8ZcESJMI=";
  env.CGO_ENABLED = "0";
  ldflags = [ "-X main.diffCommand=${diffutils}/bin/diff" ];
  meta.mainProgram = "web-client-html";
}
