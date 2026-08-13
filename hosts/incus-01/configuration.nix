{ configurationName, pkgs, ... }:

{
  imports = [
    ./hardening.nix
    ./kernel.nix
  ];

  networking.hostName = configurationName;

  system.autoUpgrade = {
    enable = true;
    flake = "github:s3-odara/infra#${configurationName}";
    upgrade = false;
    allowReboot = true;
  };

  # UEFI mode
  boot.loader.systemd-boot = {
    enable = true;
    bootCounting.enable = true;
  };
  boot.loader.efi.canTouchEfiVariables = true;

  # minimal kernelにNixOSの汎用initrd module群を要求せず、VPSに必要なmoduleだけを含める
  boot.initrd.includeDefaultModules = false;
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
    "nvme"
    "ahci"
    "ata_piix"
  ];
  boot.kernelModules = [ "wireguard" ];

  networking.useNetworkd = true;
  networking.useDHCP = true;

  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  users.users.root.hashedPassword = "!";

  users.users.me = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "incus" ];

    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICblPjqCTllD9zDPGS++Urlw4XqyXixufgn8iFEoDnkK"
    ];

    # nixos-anywhere --extra-files ./bootstrap
    hashedPasswordFile = "/etc/nixos-secrets/me-password-hash";
  };

  security.sudo.enable = false;
  security.doas = {
    enable = true;
    extraRules = [
      {
        users = [ "me" ];
        persist = true;
      }
    ];
  };

  virtualisation.incus.enable = true;
  networking.nftables.enable = true;
  networking.nftables.flushRuleset = false;

  # instanceからIncus bridge上のホストが提供するDHCP/DNSへ到達できるようにする
  networking.firewall.interfaces.incusbr0 = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [ 53 67 ];
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  environment.systemPackages = with pkgs; [
    git
    just
  ];

  system.stateVersion = "26.05";
}
