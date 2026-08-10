{ ... }:

{
  boot.isContainer = true;
  networking.hostName = "nsd";
  networking.useDHCP = true;
  networking.firewall.enable = false;

  services.nsd = {
    enable = true;
    interfaces = [
      "0.0.0.0"
      "::"
    ];
    serverCount = 1;
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
        odarah.org. 3600 IN SOA ns.odarah.org. HOSTMASTER.S3-ODARA.NET. 2024090204 3600 1800 604800 600
        odarah.org. 3600 IN NS ns.odarah.org.
        odarah.org. 3600 IN A 127.0.0.1
        ns.odarah.org. 3600 IN A 167.179.72.51
        xmpp.odarah.org. 3600 IN A 167.179.72.51
        conference.xmpp.odarah.org. 3600 IN A 167.179.72.51
        share.xmpp.odarah.org. 3600 IN A 167.179.72.51
        www.odarah.org. 3600 IN A 35.185.44.232
        odarah.org. 3600 IN AAAA ::1
        ns.odarah.org. 3600 IN AAAA 2001:19f0:7001:42b3:5400:05ff:fe13:a48d
        xmpp.odarah.org. 3600 IN AAAA 2001:19f0:7001:42b3:5400:05ff:fe13:a48d
        conference.xmpp.odarah.org. 3600 IN AAAA 2001:19f0:7001:42b3:5400:05ff:fe13:a48d
        share.xmpp.odarah.org. 3600 IN AAAA 2001:19f0:7001:42b3:5400:05ff:fe13:a48d
        www.odarah.org. 3600 IN AAAA 2600:1901:0:7b8a::
        odarah.org. 3600 IN CAA 0 issuemail ";"
        odarah.org. 3600 IN CAA 0 issuewild ";"
        odarah.org. 3600 IN CAA 0 issue "letsencrypt.org"
        odarah.org. 3600 IN CAA 0 iodef "mailto:hostmaster@s3-odara.net"
        mbo0003._domainkey.mailinglist.odarah.org. 3600 IN CNAME mbo0003._domainkey.odarah.org.
        mbo0004._domainkey.mailinglist.odarah.org. 3600 IN CNAME mbo0004._domainkey.odarah.org.
        odarah.org. 3600 IN LOC 35 54 33.931 N 138 36 44.221 E 2418.43m 0.00m 0.00m 0.00m
        mailinglist.odarah.org. 3600 IN MX 20 mxext3.mailbox.org.
        mailinglist.odarah.org. 3600 IN MX 10 mxext2.mailbox.org.
        mailinglist.odarah.org. 3600 IN MX 10 mxext1.mailbox.org.
        odarah.org. 86400 IN MX 20 mxext3.mailbox.org.
        odarah.org. 86400 IN MX 10 mxext2.mailbox.org.
        odarah.org. 86400 IN MX 10 mxext1.mailbox.org.
        _dmarc.mailinglist.odarah.org. 3600 IN TXT "v=DMARC1; p=none; sp=reject; aspf=s; adkim=s; rua=mailto:mailreport@s3-odara.net; ruf=mailto:postmaster@s3-odara.net; fo=1"
        _dmarc.odarah.org. 3600 IN TXT "v=DMARC1; p=reject; sp=reject; aspf=s; adkim=s; rua=mailto:mailreport@s3-odara.net; ruf=mailto:postmaster@s3-odara.net; fo=1"
        mailinglist.odarah.org. 3600 IN TXT "v=spf1 include:mailbox.org ~all"
        mailinglist.odarah.org._report._dmarc.odarah.org. 3600 IN TXT "v=DMARC1;"
        mbo0001._domainkey.mailinglist.odarah.org. 3600 IN TXT "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2K4PavXoNY8eGK2u61LIQlOHS8f5sWsCK5b+HMOfo0M+aNHwfqlVdzi/IwmYnuDKuXYuCllrgnxZ4fG4yVaux58v9grVsFHdzdjPlAQfp5rkiETYpCMZwgsmdseJ4CoZaosPHLjPum" "FE/Ua2WAQQljnunsM9TONM9L6KxrO9t5IISD1XtJb0bq1lVI/e72k3mnPd/q77qzhTDmwN4TSNJZN8sxzUJx9HNSMRRoEIHSDLTIJUK+Up8IeCx0B7CiOzG5w/cHyZ3AM5V8lkqBaTDK46AwTkTVGJf59QxUZArG3FEH5vy9HzDmy0tGG+053/x4RqkhqMg5/ClDm+lp" "ZqWwIDAQAB"
        mbo0001._domainkey.odarah.org. 3600 IN TXT "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2K4PavXoNY8eGK2u61LIQlOHS8f5sWsCK5b+HMOfo0M+aNHwfqlVdzi/IwmYnuDKuXYuCllrgnxZ4fG4yVaux58v9grVsFHdzdjPlAQfp5rkiETYpCMZwgsmdseJ4CoZaosPHLjPum" "FE/Ua2WAQQljnunsM9TONM9L6KxrO9t5IISD1XtJb0bq1lVI/e72k3mnPd/q77qzhTDmwN4TSNJZN8sxzUJx9HNSMRRoEIHSDLTIJUK+Up8IeCx0B7CiOzG5w/cHyZ3AM5V8lkqBaTDK46AwTkTVGJf59QxUZArG3FEH5vy9HzDmy0tGG+053/x4RqkhqMg5/ClDm+lp" "ZqWwIDAQAB"
        mbo0002._domainkey.mailinglist.odarah.org. 3600 IN TXT "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAqxEKIg2c48ecfmy/+rj35sBOhdfIYGNDCMeHy0b36DX6MNtS7zA/VDR2q5ubtHzraL5uUGas8kb/33wtrWFYxierLRXy12qj8ItdYCRugu9tXTByEED05WdBtRzJmrb8YBMfeK0E0K" "3wwoWfhIk/wzKbjMkbqYBOTYLlIcVGQWzOfN7/n3n+VChfu6sGFK3k2qrJNnw22iFy4C8Ks7j77+tCpm0PoUwA2hOdLrRw3ldx2E9PH0GVwIMJRgekY6cS7DrbHrj/AeGlwfwwCSi9T23mYvc79nVrh2+82ZqmkpZSTD2qq+ukOkyjdRuUPck6e2b+x141Nzd81dIZVf" "OEiwIDAQAB"
        mbo0002._domainkey.odarah.org. 3600 IN TXT "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAqxEKIg2c48ecfmy/+rj35sBOhdfIYGNDCMeHy0b36DX6MNtS7zA/VDR2q5ubtHzraL5uUGas8kb/33wtrWFYxierLRXy12qj8ItdYCRugu9tXTByEED05WdBtRzJmrb8YBMfeK0E0K" "3wwoWfhIk/wzKbjMkbqYBOTYLlIcVGQWzOfN7/n3n+VChfu6sGFK3k2qrJNnw22iFy4C8Ks7j77+tCpm0PoUwA2hOdLrRw3ldx2E9PH0GVwIMJRgekY6cS7DrbHrj/AeGlwfwwCSi9T23mYvc79nVrh2+82ZqmkpZSTD2qq+ukOkyjdRuUPck6e2b+x141Nzd81dIZVf" "OEiwIDAQAB"
        mbo0003._domainkey.odarah.org. 3600 IN TXT "v=DKIM1; k=ed25519; p=k1A30Je8LhsVpcOQrwHOnw0OUj3BP0gXh8nHOgl6t4Y="
        mbo0004._domainkey.odarah.org. 3600 IN TXT "v=DKIM1; k=ed25519; p=mLyBxtALVny3i4fn1fgHiXWWzk4XtNbmq4Jcmfkd8p8="
        _mta-sts.odarah.org. 3600 IN TXT "v=STSv1; id=20240407003138"
        odarah.org. 3600 IN TXT "my pgp fpr: B353 1E57 3A66 76E8 A920 60B3 879D 4D00 108D 4015"
        odarah.org. 3600 IN TXT "v=spf1 include:mailbox.org ~all"
        _gitlab-pages-verification-code.www.odarah.org. 3600 IN TXT "gitlab-pages-verification-code=af367ae4323acd54e4933f0da74773dc"
        _acme-challenge.conference.xmpp.odarah.org. 30 IN TXT "Uhra1SiXxxCma-XMdCJRlCVtRilEBvPPcRdGsv1ky8k"
      '';

      "51.72.179.167.in-addr.arpa.".data = ''
        51.72.179.167.in-addr.arpa. 3600 IN SOA NS.ODARAH.ORG. HOSTMASTER.S3-ODARA.NET. 20240902 3600 1800 604800 600
        51.72.179.167.in-addr.arpa. 86400 IN NS ns.odarah.org.
        51.72.179.167.in-addr.arpa. 3600 IN PTR odarah.org.
      '';
    };
  };

  system.stateVersion = "26.05";
}
