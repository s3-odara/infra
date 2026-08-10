{
  description = "NixOS + Incus infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, disko, ... }: {
    nixosConfigurations = {
      incus-01 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
  
        modules = [
          disko.nixosModules.disko
          ./hosts/incus-01/disko.nix
          ./hosts/incus-01/configuration.nix
        ];
      };

      prosody = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./guests/prosody/configuration.nix
        ];
      };

      knot = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./guests/knot/configuration.nix
        ];
      };
    };
  };
}
