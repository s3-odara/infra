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
      "odarah.org.".data = ''
        odarah.org. 3600 IN SOA ns.odarah.org. HOSTMASTER.S3-ODARA.NET. 2026081801 3600 1800 604800 600
        odarah.org. 3600 IN NS ns.odarah.org.
        odarah.org. 3600 IN A 127.0.0.1
        ns.odarah.org. 120 IN A 15.235.184.173
        xmpp.odarah.org. 120 IN A 15.235.184.173
        _xmpp-client._tcp.xmpp.odarah.org. 3600 IN SRV 0 5 5222 xmpp.odarah.org.
        _xmpps-client._tcp.xmpp.odarah.org. 3600 IN SRV 0 5 5223 xmpp.odarah.org.
        _xmpp-server._tcp.xmpp.odarah.org. 3600 IN SRV 0 5 5269 xmpp.odarah.org.
        conference.xmpp.odarah.org. 120 IN A 15.235.184.173
        share.xmpp.odarah.org. 120 IN A 15.235.184.173
        odarah.org. 3600 IN CAA 0 issuemail ";"
        odarah.org. 3600 IN CAA 0 issuewild ";"
        odarah.org. 3600 IN CAA 0 issue "letsencrypt.org"
        odarah.org. 3600 IN CAA 0 iodef "mailto:hostmaster@s3-odara.net"
        odarah.org. 3600 IN LOC 35 54 33.931 N 138 36 44.221 E 2418.43m 0.00m 0.00m 0.00m
        _dmarc.mailinglist.odarah.org. 3600 IN TXT "v=DMARC1; p=none; sp=reject; aspf=s; adkim=s; rua=mailto:mailreport@s3-odara.net; ruf=mailto:postmaster@s3-odara.net; fo=1"
        _dmarc.odarah.org. 3600 IN TXT "v=DMARC1; p=reject; sp=reject; aspf=s; adkim=s; rua=mailto:mailreport@s3-odara.net; ruf=mailto:postmaster@s3-odara.net; fo=1"
        mailinglist.odarah.org. 3600 IN TXT "v=spf1 ~all"
        mailinglist.odarah.org._report._dmarc.odarah.org. 3600 IN TXT "v=DMARC1;"
        _mta-sts.odarah.org. 3600 IN TXT "v=STSv1; id=20240407003138"
        odarah.org. 3600 IN TXT "my pgp fpr: B353 1E57 3A66 76E8 A920 60B3 879D 4D00 108D 4015"
        odarah.org. 3600 IN TXT "v=spf1 ~all"
      '';

      "51.72.179.167.in-addr.arpa.".data = ''
        51.72.179.167.in-addr.arpa. 3600 IN SOA NS.ODARAH.ORG. HOSTMASTER.S3-ODARA.NET. 20240902 3600 1800 604800 600
        51.72.179.167.in-addr.arpa. 86400 IN NS ns.odarah.org.
        51.72.179.167.in-addr.arpa. 3600 IN PTR odarah.org.
      '';
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
