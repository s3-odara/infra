{
  description = "NixOS + Incus infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable-small";

    # Use upstream packaging and its own nixpkgs, not the system package set.
    # Stable-release policy and approved exceptions: docs/operations.md.
    sable-next.url = "git+https://git.sable.moe/SableClient/sable-next?ref=refs/tags/v26.11.4&rev=0280a39acacb2df93382b7419ace324eee265c03&shallow=1";

    # Temporary until nixpkgs packages 2.1.0. Keep upstream's own dependency pins.
    # Build in our CI; do not add upstream's binary caches or trusted keys.
    tuwunel.url = "git+https://github.com/matrix-construct/tuwunel?ref=refs/tags/v2.1.0&rev=4b0d90d9743e3f084815b37dcd986bb7efcea1fd&shallow=1";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-images = {
      url = "github:nix-community/nixos-images";
      inputs.nixos-unstable.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      disko,
      nixos-images,
      sable-next,
      sops-nix,
      tuwunel,
      ...
    }:
    let
      checkSygnalPins =
        nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/check-sygnal-pins/package.nix
          { };
      nixStoreDedup =
        nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/nix-store-dedup/package.nix
          { };

      matrixTuwunelUpstream =
        { pkgs, ... }:
        {
          services.matrix-tuwunel.package = tuwunel.packages.${pkgs.stdenv.hostPlatform.system}.default;
        };

      kexecInstaller =
        (nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            nixos-images.nixosModules.kexec-installer
            {
              disabledModules = [
                (nixos-images.outPath + "/nix/restore-remote-access.nix")
                (nixos-images.outPath + "/nix/zfs-minimal.nix")
              ];
              imports = [
                nixos-images.nixosModules.noninteractive
                ./modules/nixos-images/restore-remote-access.nix
              ];
              boot.supportedFilesystems.zfs = false;
              system.kexec-installer.name = "nixos-kexec-installer-noninteractive";
            }
          ];
        }).config.system.build.kexecInstallerTarball;
    in
    {
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;
      checks.x86_64-linux = {
        check-sygnal-pins = checkSygnalPins;
        nix-store-dedup = nixStoreDedup;
      };

      packages.x86_64-linux = {
        age = nixpkgs.legacyPackages.x86_64-linux.age;
        check-sygnal-pins = checkSygnalPins;
        curl = nixpkgs.legacyPackages.x86_64-linux.curl;
        eturnal = nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/eturnal/package.nix { };
        gh = nixpkgs.legacyPackages.x86_64-linux.gh;
        gnupg = nixpkgs.legacyPackages.x86_64-linux.gnupg;
        jq = nixpkgs.legacyPackages.x86_64-linux.jq;
        matrix-bot = nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/matrix-bot/package.nix { };
        mkpasswd = nixpkgs.legacyPackages.x86_64-linux.mkpasswd;
        kexec-installer = kexecInstaller;
        nixos-anywhere = nixpkgs.legacyPackages.x86_64-linux.nixos-anywhere;
        nix-store-dedup = nixStoreDedup;
        opentofu = nixpkgs.legacyPackages.x86_64-linux.opentofu;
        sable = sable-next.packages.x86_64-linux.sable-unwrapped;
        shfmt = nixpkgs.legacyPackages.x86_64-linux.shfmt;
        sygnal = nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/sygnal/package.nix { };
        sops = nixpkgs.legacyPackages.x86_64-linux.sops;
        # Cache tuwunel 2.1.0's IFD input for build-disabled guests.
        # Keep the Rust version and hash in sync with the pinned upstream flake.
        tuwunel-rust-manifest = nixpkgs.legacyPackages.x86_64-linux.fetchurl {
          url = "https://static.rust-lang.org/dist/channel-rust-1.97.1.toml";
          hash = "sha256-A1abGIbOtcBSdrUMhDGrER3pRM1hQP4fp9gh3Y4PKc8=";
        };
        web-client-html =
          nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/web-client-html/package.nix
            { };
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

        knot = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs.configurationName = "knot";
          modules = [
            sops-nix.nixosModules.sops
            ./modules/guest
            ./modules/guest/secrets.nix
            ./guests/knot/configuration.nix
          ];
        };

        nginx = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            configurationName = "nginx";
            sable-unwrapped = sable-next.packages.x86_64-linux.sable-unwrapped;
          };
          modules = [
            sops-nix.nixosModules.sops
            ./modules/guest
            ./modules/guest/secrets.nix
            ./guests/nginx/configuration.nix
          ];
        };

        tuwunel = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs.configurationName = "tuwunel";
          modules = [
            sops-nix.nixosModules.sops
            ./modules/guest
            ./modules/guest/secrets.nix
            matrixTuwunelUpstream
            ./guests/tuwunel/configuration.nix
          ];
        };

        tuwunel-guest = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs.configurationName = "tuwunel-guest";
          modules = [
            ./modules/guest
            matrixTuwunelUpstream
            ./guests/tuwunel-guest/configuration.nix
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

        radicale = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs.configurationName = "radicale";
          modules = [
            sops-nix.nixosModules.sops
            ./modules/guest
            ./modules/guest/secrets.nix
            ./guests/radicale/configuration.nix
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
