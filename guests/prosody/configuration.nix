{ ... }:

{
  boot.isContainer = true;
  networking.hostName = "prosody";
  networking.useDHCP = true;
  networking.firewall.enable = false;

  services.prosody = {
    enable = true;
    allowRegistration = false;
    xmppComplianceSuite = false;

    admins = [
      "admin@example.net"
    ];

    virtualHosts.main = {
      enabled = true;
      domain = "example.net";
    };
  };

  system.stateVersion = "26.05";
}
