{
  description = "NixOS + Incus infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.disko.follows = "disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, disko, nixos-anywhere, ... }: {
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

    packages.x86_64-linux = {
      mkpasswd = nixpkgs.legacyPackages.x86_64-linux.mkpasswd;
      nixos-anywhere = nixos-anywhere.packages.x86_64-linux.nixos-anywhere;
    };

    nixosConfigurations = {
      incus-01 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs.configurationName = "incus-01";

        modules = [
          disko.nixosModules.disko
          ./hosts/incus-01/disko.nix
          ./hosts/incus-01/configuration.nix
        ];
      };

      prosody = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs.configurationName = "prosody";
        modules = [
          ./guests/prosody/configuration.nix
        ];
      };

      nsd = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs.configurationName = "nsd";
        modules = [
          ./guests/nsd/configuration.nix
        ];
      };

      wireguard = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs.configurationName = "wireguard";
        modules = [
          ./guests/wireguard/configuration.nix
        ];
      };
    };
  };
}
