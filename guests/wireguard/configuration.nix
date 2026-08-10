{ pkgs, ... }:

{
  boot.isContainer = true;
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  networking.hostName = "wireguard";
  networking.useDHCP = true;
  networking.firewall.enable = false;

  networking.wg-quick.interfaces.wg0 = {
    mtu = 1420;
    listenPort = 443;
    privateKeyFile = "/etc/nixos-secrets/wireguard/wg0.key";

    postUp = ''
      ${pkgs.iptables}/bin/iptables -A FORWARD -i wg0 -j ACCEPT
      ${pkgs.iptables}/bin/iptables -A FORWARD -o wg0 -j ACCEPT
      ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
    '';

    postDown = ''
      ${pkgs.iptables}/bin/iptables -D FORWARD -i wg0 -j ACCEPT
      ${pkgs.iptables}/bin/iptables -D FORWARD -o wg0 -j ACCEPT
      ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
    '';

    peers = [
      {
        publicKey = "tG03yW2hbB7vxQMdbS8RTBwKr4O5trXYyFvOFAnTNGo=";
        presharedKeyFile = "/etc/nixos-secrets/wireguard/peer-10.0.0.2.psk";
        allowedIPs = [ "10.0.0.2/32" ];
        endpoint = "125.14.64.70:59706";
      }
      {
        publicKey = "Hm+KOv+BNllpMsYghno5wWIDYpEuWdaOHcXWntcSMGM=";
        presharedKeyFile = "/etc/nixos-secrets/wireguard/peer-10.0.0.3.psk";
        allowedIPs = [ "10.0.0.3/32" ];
        endpoint = "125.14.64.115:40304";
      }
    ];
  };

  system.stateVersion = "26.05";
}
