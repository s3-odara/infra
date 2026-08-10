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
    apps.x86_64-linux.infra = {
      type = "app";

      program = "${
        nixpkgs.legacyPackages.x86_64-linux.writeShellApplication {
          name = "infra";

          runtimeInputs = [
            nixpkgs.legacyPackages.x86_64-linux.opentofu
          ];

          text = builtins.readFile ./scripts/infra.sh;
        }
      }/bin/infra";

      meta.description = "Deploy the NixOS and Incus infrastructure";
    };

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

      nsd = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./guests/nsd/configuration.nix
        ];
      };

      wireguard = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./guests/wireguard/configuration.nix
        ];
      };
    };
  };
}
