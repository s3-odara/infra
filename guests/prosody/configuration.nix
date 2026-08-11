{ configurationName, ... }:

{
  boot.isContainer = true;
  networking.hostName = configurationName;
  networking.useDHCP = true;
  networking.firewall.enable = false;

  system.autoUpgrade = {
    enable = true;
    flake = "github:s3-odara/infra#${configurationName}";
    upgrade = false;
    allowReboot = false;
    randomizedDelaySec = "1h";
    fixedRandomDelay = true;
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  services.prosody = {
    enable = true;
    checkConfig = true;
    admins = [ ];
    httpPorts = [ 80 ];
    httpsPorts = [ 443 ];
    allowRegistration = false;
    authentication = "internal_hashed";
    c2sRequireEncryption = true;
    s2sRequireEncryption = true;
    s2sSecureAuth = true;

    virtualHosts = {
      localhost = {
        enabled = true;
        domain = "localhost";
      };
      main = {
        enabled = true;
        domain = "xmpp.odarah.org";
      };
    };

    muc = [
      {
        domain = "conference.xmpp.odarah.org";
      }
    ];

    httpFileShare = {
      domain = "share.xmpp.odarah.org";
      size_limit = 100 * 1024 * 1024;
      daily_quota = 1024 * 1024 * 1024;
      global_quota = 10 * 1024 * 1024 * 1024;
    };

    modules = {
      admin_adhoc = false;
      bosh = true;
      limits = true;
      proxy65 = false;
      websocket = true;
    };

    extraModules = [
      "account_activity"
      "csi_simple"
      "invites"
      "invites_adhoc"
      "invites_register"
      "turn_external"
      "vcard4"
    ];

    extraConfig = ''
      limits = {
        c2s = { rate = "10kb/s" };
        s2sin = { rate = "30kb/s" };
      }
      storage = "internal"
      archive_store = "memory"
      archive_expires_after = "1w"
      turn_external_host = "xmpp.odarah.org"
      turn_external_secret = "$TURN_EXTERNAL_SECRET"
    '';
  };

  systemd.services.prosody.serviceConfig.EnvironmentFile =
    "/etc/nixos-secrets/prosody.env";

  system.stateVersion = "26.05";
}
