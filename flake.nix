{
  description = "NixOS + Incus infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable-small";

    # Use upstream packaging and its own nixpkgs, not the system package set.
    # Stable-release policy and approved exceptions: docs/operations.md.
    sable-next.url = "git+https://git.sable.moe/SableClient/sable-next?ref=refs/tags/v2.3.9&rev=2b9e33610e91b49b77ab48f0b1e2837dd5ecbaf5&shallow=1";

    # Temporary until nixpkgs packages 2.0.0. Keep upstream's own dependency pins.
    # Build in our CI; do not add upstream's binary caches or trusted keys.
    tuwunel.url = "git+https://github.com/matrix-construct/tuwunel?ref=refs/tags/v2.0.0&rev=a3feae1a26ec764ee88606c2c68b659a9b5fba8d&shallow=1";

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

      sableUnwrapped =
        let
          upstream = sable-next.packages.x86_64-linux.sable-unwrapped;
        in
        if upstream.version == "2.3.9" then
          upstream.overrideAttrs (old: {
            # v2.3.9 pins an incorrect Cargo vendor hash.
            cargoDeps = old.cargoDeps.overrideAttrs (deps: {
              vendorStaging = deps.vendorStaging.overrideAttrs {
                outputHash = "sha256-hhTjjNlAzGmniTa7r15LXaZicgKEEyLcuKkJlNsLCl0=";
              };
            });
          })
        else
          upstream;

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
        kexec-installer = kexecInstaller;
        nixos-anywhere = nixpkgs.legacyPackages.x86_64-linux.nixos-anywhere;
        opentofu = nixpkgs.legacyPackages.x86_64-linux.opentofu;
        sable = sableUnwrapped;
        shfmt = nixpkgs.legacyPackages.x86_64-linux.shfmt;
        sygnal = nixpkgs.legacyPackages.x86_64-linux.callPackage ./packages/sygnal/package.nix { };
        sops = nixpkgs.legacyPackages.x86_64-linux.sops;
        # Cache tuwunel 2.0.0's IFD input for build-disabled guests.
        # Keep the Rust version and hash in sync with the pinned upstream flake.
        tuwunel-rust-manifest = nixpkgs.legacyPackages.x86_64-linux.fetchurl {
          url = "https://static.rust-lang.org/dist/channel-rust-1.95.0.toml";
          hash = "sha256-gh/xTkxKHL4eiRXzWv8KP7vfjSk61Iq48x47BEDFgfk=";
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
            sable-unwrapped = sableUnwrapped;
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
