{
  description = "NixOS + Incus infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # TEMP: tuwunel 1.9.0 が nixos-unstable に入るまでの暫定ピン
    # (nixos-unstable の tip はまだ 1.8.3)。unstable が追いついたら削除する。
    nixpkgs-2605.url = "github:NixOS/nixpkgs/nixos-26.05";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.disko.follows = "disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-2605,
      disko,
      nixos-anywhere,
      sops-nix,
      ...
    }:
    {
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;

      packages.x86_64-linux = {
        age = nixpkgs.legacyPackages.x86_64-linux.age;
        curl = nixpkgs.legacyPackages.x86_64-linux.curl;
        eturnal = nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/eturnal/package.nix { };
        jq = nixpkgs.legacyPackages.x86_64-linux.jq;
        matrix-invite-bot =
          nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/matrix-invite-bot/package.nix
            { };
        mkpasswd = nixpkgs.legacyPackages.x86_64-linux.mkpasswd;
        nix-prefetch-docker = nixpkgs.legacyPackages.x86_64-linux.nix-prefetch-docker;
        nixos-anywhere = nixos-anywhere.packages.x86_64-linux.nixos-anywhere;
        opentofu = nixpkgs.legacyPackages.x86_64-linux.opentofu;
        python3 = nixpkgs.legacyPackages.x86_64-linux.python3;
        sable = nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/sable/package.nix { };
        shfmt = nixpkgs.legacyPackages.x86_64-linux.shfmt;
        sygnal = nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/sygnal/package.nix { };
        sops = nixpkgs.legacyPackages.x86_64-linux.sops;
      };

      nixosConfigurations = {
        mecha-vultr = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs.configurationName = "mecha-vultr";

          modules = [
            disko.nixosModules.disko
            ./modules/host
            ./hosts/mecha-vultr/disko.nix
            ./hosts/mecha-vultr/configuration.nix
          ];
        };

        tencha-conoha = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs.configurationName = "tencha-conoha";

          modules = [
            disko.nixosModules.disko
            ./modules/host
            ./hosts/tencha-conoha/disko.nix
            ./hosts/tencha-conoha/configuration.nix
          ];
        };

        aracha-ovh = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs.configurationName = "aracha-ovh";

          modules = [
            disko.nixosModules.disko
            ./modules/host
            ./hosts/aracha-ovh/disko.nix
            ./hosts/aracha-ovh/configuration.nix
          ];
        };

        prosody = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs.configurationName = "prosody";
          modules = [
            sops-nix.nixosModules.sops
            ./modules/guest
            ./modules/guest/secrets.nix
            ./guests/prosody/configuration.nix
          ];
        };

        nsd = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs.configurationName = "nsd";
          modules = [
            ./modules/guest
            ./guests/nsd/configuration.nix
          ];
        };

        nginx = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs.configurationName = "nginx";
          modules = [
            sops-nix.nixosModules.sops
            ./modules/guest
            ./modules/guest/secrets.nix
            ./guests/nginx/configuration.nix
          ];
        };

        tuwunel = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            configurationName = "tuwunel";
            inherit nixpkgs-2605;
          };
          modules = [
            sops-nix.nixosModules.sops
            ./modules/guest
            ./modules/guest/secrets.nix
            ./guests/tuwunel/configuration.nix
          ];
        };

        sygnal = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs.configurationName = "sygnal";
          modules = [
            sops-nix.nixosModules.sops
            ./modules/guest
            ./modules/guest/secrets.nix
            ./guests/sygnal/configuration.nix
          ];
        };

        rtc = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs.configurationName = "rtc";
          modules = [
            sops-nix.nixosModules.sops
            ./modules/guest
            ./modules/guest/secrets.nix
            ./guests/rtc/configuration.nix
          ];
        };

        wireguard = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs.configurationName = "wireguard";
          modules = [
            sops-nix.nixosModules.sops
            ./modules/guest
            ./modules/guest/secrets.nix
            ./guests/wireguard/configuration.nix
          ];
        };
      };
    };
}
