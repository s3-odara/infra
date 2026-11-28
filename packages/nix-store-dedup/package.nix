{ buildGoModule }:

buildGoModule {
  pname = "nix-store-dedup";
  version = "0.1.0";
  src = ./.;
  vendorHash = null;
  env.CGO_ENABLED = "0";
  meta.mainProgram = "nix-store-dedup";
}
