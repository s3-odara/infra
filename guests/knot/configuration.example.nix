{ pkgs, ... }:

let
  zoneFile = pkgs.writeText "example.net.zone" ''
    $ORIGIN example.net.
    $TTL 3600

    @ IN SOA ns1.example.net. hostmaster.example.net. (
      2026081001
      3600
      900
      1209600
      300
    )

    @ IN NS ns1.example.net.

    # 実際のVultr public IPv4に変更
    ns1  IN A 192.0.2.10
    @    IN A 192.0.2.10
    xmpp IN A 192.0.2.10

    _xmpp-client._tcp IN SRV 0 5 5222 xmpp.example.net.
    _xmpp-server._tcp IN SRV 0 5 5269 xmpp.example.net.
  '';
in
{
  boot.isContainer = true;
  networking.hostName = "knot";
  networking.useDHCP = true;
  networking.firewall.enable = false;

  services.knot = {
    enable = true;
    settings = {
      server.listen = [ "0.0.0.0@53" ];
      zone."example.net".file = zoneFile;
      log.syslog.any = "info";
    };
  };

  system.stateVersion = "26.05";
}
