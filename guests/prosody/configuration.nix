{ config, configurationName, ... }:

{
  boot.isContainer = true;
  networking.hostName = configurationName;
  networking.useDHCP = true;
  networking.firewall.enable = false;

  services.prosody = {
    enable = true;
    checkConfig = true;
    admins = [
      "odara@xmpp.odarah.org"
    ];
    httpPorts = [ 80 ];
    httpsPorts = [ 443 ];
    allowRegistration = true;
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
        restrictRoomCreation = "local";
        roomDefaultPublic = false;

        extraConfig = ''
          muc_room_default_persistent = true
        '';
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
    ];

    extraConfig = ''
      limits = {
        c2s = { rate = "10kb/s" };
        s2sin = { rate = "30kb/s" };
      }
      storage = "internal"
      archive_expires_after = "2w"
      registration_invite_only = true
      turn_external_host = "xmpp.odarah.org"
      turn_external_secret = "$TURN_EXTERNAL_SECRET"
    '';
  };

  sops = {
    secrets.turn_external_secret = { };
    templates."prosody.env" = {
      content = ''
        TURN_EXTERNAL_SECRET=${config.sops.placeholder.turn_external_secret}
      '';
      mode = "0400";
      reloadUnits = [ "prosody.service" ];
    };
  };

  systemd.services.prosody.serviceConfig.EnvironmentFile = config.sops.templates."prosody.env".path;

  system.stateVersion = "26.05";
}
