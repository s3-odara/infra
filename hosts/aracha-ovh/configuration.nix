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

  system.autoUpgrade = {
    enable = true;
    flake = "github:s3-odara/infra#${configurationName}";
    upgrade = false;
    allowReboot = true;
  };

  # OVH currently presents this VPS through legacy BIOS, not UEFI.
  boot.loader.grub.enable = true;

  # Required storage, network, and WireGuard drivers are built into the kernel.
  boot.initrd.includeDefaultModules = false;
  boot.initrd.allowMissingModules = true;
  # Incus requests this for VM support, which this container-only host omits.
  boot.kernelModules.vhost_vsock = lib.mkForce false;
  boot.initrd.systemd.tpm2.enable = false;
  systemd.tpm2.enable = false;

  # BBR congestion control with the fq qdisc (both built into the kernel),
  # and Explicit Congestion Notification negotiated on every connection.
  boot.kernel.sysctl = {
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.core.default_qdisc" = "fq";
    # value 1 = enable classic ECN both incoming/outgoing
    "net.ipv4.tcp_ecn" = 1;
    "net.ipv4.tcp_ecn_fallback" = 1;
  };

  networking = {
    useNetworkd = true;
    useDHCP = false;
    enableIPv6 = false;
  };

  systemd.network.networks."10-uplink" = {
    matchConfig.MACAddress = "fa:16:3e:f0:bc:d0";
    networkConfig.DHCP = "ipv4";
  };

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
