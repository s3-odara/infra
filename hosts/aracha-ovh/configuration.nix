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

  systemd.network.links."10-uplink" = {
    matchConfig.MACAddress = "fa:16:3e:f0:bc:d0";
    linkConfig.Name = "uplink0";
  };

  systemd.network.networks."10-uplink" = {
    matchConfig.Name = "uplink0";
    networkConfig.DHCP = "ipv4";
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
  services.fstrim.enable = false;
  networking.nftables.enable = true;
  networking.nftables.flushRuleset = false;

  # Tuwunel uses the public Push URL to retain SSRF protection, but Incus does
  # not DNAT bridge-originated traffic and DNAT alone has an asymmetric return
  # path. Do not SNAT the shared HTTPS forward because that would hide client
  # IPs; DNAT and masquerade only this Tuwunel-to-nginx hairpin flow.
  networking.nftables.tables."incus-hairpin" = {
    family = "ip";
    content = ''
      chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        iifname "incusbr0" ip saddr 10.77.3.14 ip daddr 15.235.184.173 tcp dport 443 dnat to 10.77.3.13:443
      }

      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 10.77.3.14 ip daddr 10.77.3.13 tcp dport 443 ct status dnat masquerade
      }
    '';
  };

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
