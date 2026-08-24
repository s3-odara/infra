{ ... }:

{
  sops = {
    age.keyFile = "/var/lib/sops-nix/key.txt";
    defaultSopsFile = "/var/lib/sops-nix/secrets.sops.yaml";
    defaultSopsFormat = "yaml";
    validateSopsFiles = false;
  };
}
