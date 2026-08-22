{ configurationName, ... }:

{
  boot.isContainer = true;
  networking.hostName = configurationName;
  networking.useDHCP = true;
  networking.firewall.enable = false;

  services.nsd = {
    enable = true;
    interfaces = [ "0.0.0.0" ];
    ipv6 = false;
    serverCount = 1;
    tcpCount = 100;
    tcpQueryCount = 0;
    tcpTimeout = 120;
    hideVersion = true;
    ipv4EDNSSize = 512;
    ipv6EDNSSize = 512;

    ratelimit = {
      enable = true;
      ratelimit = 200;
      size = 1000000;
      whitelistRatelimit = 2000;
    };

    extraConfig = ''
      server:
        answer-cookie: yes
        hide-identity: yes
        refuse-any: yes
    '';

    zones = {
      "odarah.org.".data = builtins.readFile ./zones/odarah.org.zone;

      "173.184.235.15.in-addr.arpa.".data = builtins.readFile ./zones/173.184.235.15.in-addr.arpa.zone;
    };
  };

  systemd.services.nsd.serviceConfig = {
    NoNewPrivileges = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    SystemCallArchitectures = "native";
    RestrictNamespaces = true;
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_NETLINK"
      "AF_INET"
      "AF_INET6"
    ];
    SystemCallFilter = [
      "~@clock"
      "~@cpu-emulation"
      "~@debug"
      "~@keyring"
      "~@module"
      "~@mount"
      "chroot"
      "~@obsolete"
      "~@resources"
    ];
  };

  system.stateVersion = "26.05";
}
