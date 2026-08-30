{
  configurationName,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ./hardening.nix
    ./kernel.nix
  ];

  networking.hostName = configurationName;

  # ConoHa presents this VPS through legacy SeaBIOS, not UEFI.
  boot.loader.grub.enable = true;

  # Required storage, network, and WireGuard drivers are built into the kernel.
  boot.initrd.includeDefaultModules = false;
  boot.initrd.allowMissingModules = true;
  # Incus requests this for VM support, which this container-only host omits.
  boot.kernelModules.vhost_vsock = lib.mkForce false;
  boot.initrd.systemd.tpm2.enable = false;
  systemd.tpm2.enable = false;

  networking = {
    useNetworkd = true;
    useDHCP = false;
    enableIPv6 = false;
    nameservers = [
      "150.95.10.8"
      "150.95.10.9"
    ];
  };

  systemd.network.links."10-uplink" = {
    matchConfig.MACAddress = "fa:16:3e:7e:a8:02";
    linkConfig.Name = "uplink0";
  };

  systemd.network.networks."10-uplink" = {
    matchConfig.Name = "uplink0";

    networkConfig = {
      Address = "133.117.77.64/23";
      Gateway = "133.117.76.1";
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
  services.chrony.enableRTCTrimming = false;
  networking.nftables.enable = true;
  networking.nftables.flushRuleset = false;

  # instanceからIncus bridge上のホストが提供するDHCP/DNSへ到達できるようにする
  networking.firewall.interfaces.incusbr0 = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [
      53
      67
    ];
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  environment.systemPackages = with pkgs; [
    git
    just
    opentofu
  ];

  system.stateVersion = "26.05";
}
