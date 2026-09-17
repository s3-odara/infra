{
  description = "NixOS + Incus infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    tuwunel.url = "github:matrix-construct/tuwunel/v1.9.1";

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
      sops-nix,
      tuwunel,
      ...
    }:
    let
      checkSygnalPins =
        nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/check-sygnal-pins/package.nix
          { };
      # Tuwunel 1.9.1's in-process thumbnail tests retain cyclic service
      # references and exhaust builder resources; its other database-backed
      # tests already isolate their services in child processes.
      tuwunelPackage = tuwunel.packages.x86_64-linux.default.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace src/service/media/thumbnail/tests.rs \
            --replace-fail 'async fn duplicate_waiters_do_not_fetch_before_admission' '#[ignore = "leaks service resources in the Nix builder"]
          async fn duplicate_waiters_do_not_fetch_before_admission' \
            --replace-fail 'async fn cancelled_active_caller_holds_admission_until_worker_exits' '#[ignore = "leaks service resources in the Nix builder"]
          async fn cancelled_active_caller_holds_admission_until_worker_exits' \
            --replace-fail 'async fn completed_worker_keeps_admission_while_caller_owns_source' '#[ignore = "leaks service resources in the Nix builder"]
          async fn completed_worker_keeps_admission_while_caller_owns_source' \
            --replace-fail 'fn cancelled_queued_worker_releases_admission_without_starting' '#[ignore = "leaks service resources in the Nix builder"]
          fn cancelled_queued_worker_releases_admission_without_starting'
        '';
      });
    in
    {
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;
      checks.x86_64-linux.check-sygnal-pins = checkSygnalPins;

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
        nix-prefetch-docker = nixpkgs.legacyPackages.x86_64-linux.nix-prefetch-docker;
        kexec-installer = nixos-images.packages.x86_64-linux.kexec-installer-nixos-unstable-noninteractive;
        nixos-anywhere = nixpkgs.legacyPackages.x86_64-linux.nixos-anywhere;
        opentofu = nixpkgs.legacyPackages.x86_64-linux.opentofu;
        sable = nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/sable/package.nix { };
        shfmt = nixpkgs.legacyPackages.x86_64-linux.shfmt;
        sygnal = nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/sygnal/package.nix { };
        skopeo = nixpkgs.legacyPackages.x86_64-linux.skopeo;
        sops = nixpkgs.legacyPackages.x86_64-linux.sops;
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
          specialArgs.configurationName = "tuwunel";
          modules = [
            sops-nix.nixosModules.sops
            ./modules/guest
            ./modules/guest/secrets.nix
            ./guests/tuwunel/configuration.nix
            { services.matrix-tuwunel.package = tuwunelPackage; }
          ];
        };

        tuwunel-guest = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs.configurationName = "tuwunel-guest";
          modules = [
            ./modules/guest
            ./guests/tuwunel-guest/configuration.nix
            { services.matrix-tuwunel.package = tuwunelPackage; }
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
