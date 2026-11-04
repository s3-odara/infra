{
  config,
  configurationName,
  lib,
  ...
}:

let
  nonPublicIPv4 = import ../../modules/guest/non-public-ipv4.nix;
in
{
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  networking.hostName = configurationName;
  networking.useDHCP = true;
  networking.firewall.enable = false;

  networking.nftables = {
    enable = true;
    flushRuleset = false;
    tables.wireguard-exit = {
      family = "inet";
      content = ''
        set non_public_ipv4 {
          type ipv4_addr; flags interval;
          elements = { ${lib.concatStringsSep ", " nonPublicIPv4} }
        }

        chain input {
          type filter hook input priority filter; policy accept;
          # Peers use this guest only as an Internet exit, not as a LAN host
          # or DNS resolver. The encrypted WireGuard UDP listener is on eth0.
          iifname "wg0" counter drop
        }

        chain forward {
          type filter hook forward priority filter; policy drop;
          # This guest configuration is shared by mecha-vultr and tencha-conoha.
          # Allow only DNS on their bridge gateways before blocking private IPs.
          iifname "wg0" oifname "eth0" ip daddr { 10.77.1.1, 10.77.2.1 } meta l4proto { tcp, udp } th dport 53 ct state { new, established } counter accept
          iifname "wg0" ip daddr @non_public_ipv4 counter drop
          iifname "wg0" oifname "eth0" meta nfproto ipv4 ct state { new, established, related } counter accept
          iifname "eth0" oifname "wg0" ct state { established, related } ct direction reply counter accept
          counter drop
        }

        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          iifname "wg0" oifname "eth0" meta nfproto ipv4 masquerade
        }
      '';
    };
  };

  systemd.services.wg-quick-wg0 = {
    bindsTo = [ "nftables.service" ];
    after = [ "nftables.service" ];
  };

  sops.secrets = {
    wg0_private_key.restartUnits = [ "wg-quick-wg0.service" ];
    peer_10_0_0_2_psk.restartUnits = [ "wg-quick-wg0.service" ];
    peer_10_0_0_3_psk.restartUnits = [ "wg-quick-wg0.service" ];
  };

  networking.wg-quick.interfaces.wg0 = {
    mtu = 1420;
    listenPort = 443;
    privateKeyFile = config.sops.secrets.wg0_private_key.path;

    peers = [
      {
        publicKey = "tG03yW2hbB7vxQMdbS8RTBwKr4O5trXYyFvOFAnTNGo=";
        presharedKeyFile = config.sops.secrets.peer_10_0_0_2_psk.path;
        allowedIPs = [ "10.0.0.2/32" ];
        endpoint = "125.14.64.70:59706";
      }
      {
        publicKey = "Hm+KOv+BNllpMsYghno5wWIDYpEuWdaOHcXWntcSMGM=";
        presharedKeyFile = config.sops.secrets.peer_10_0_0_3_psk.path;
        allowedIPs = [ "10.0.0.3/32" ];
        endpoint = "125.14.64.115:40304";
      }
    ];
  };

  system.stateVersion = "26.05";
}
