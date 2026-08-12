{ config, configurationName, pkgs, ... }:

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
    secrets = {
      turn_external_secret = { };
      r2_access_key_id = { };
      r2_secret_access_key = { };
      restic_repository_password = { };
    };

    templates = {
      "prosody.env" = {
        content = ''
          TURN_EXTERNAL_SECRET=${config.sops.placeholder.turn_external_secret}
        '';
        mode = "0400";
        reloadUnits = [ "prosody.service" ];
      };

      "restic-r2.env" = {
        content = ''
          AWS_ACCESS_KEY_ID=${config.sops.placeholder.r2_access_key_id}
          AWS_SECRET_ACCESS_KEY=${config.sops.placeholder.r2_secret_access_key}
          AWS_DEFAULT_REGION=auto
        '';
        owner = "root";
        group = "root";
        mode = "0400";
      };
    };
  };

  services.restic.backups = {
    prosody-short = {
      repository = "s3:https://6ecd930c8cd4dc63f87c9398762626e8.r2.cloudflarestorage.com/prosody/prosody-short";
      paths = [
        "/var/lib/prosody"
        "/etc/prosody/certs"
      ];
      environmentFile = config.sops.templates."restic-r2.env".path;
      passwordFile = config.sops.secrets.restic_repository_password.path;
      initialize = true;
      pruneOpts = [ "--keep-daily 14" ];
      backupPrepareCommand = ''
        while ! mkdir /run/prosody-backup.lock 2>/dev/null; do
          sleep 10
        done
        ${pkgs.systemd}/bin/systemctl stop prosody.service
      '';
      backupCleanupCommand = ''
        status=0
        ${pkgs.systemd}/bin/systemctl start prosody.service || status=$?
        rmdir /run/prosody-backup.lock
        exit "$status"
      '';
      timerConfig = {
        OnCalendar = "*-*-* 02:00:00";
        RandomizedDelaySec = "1h";
        FixedRandomDelay = true;
        Persistent = true;
      };
    };

    prosody-long = {
      repository = "s3:https://6ecd930c8cd4dc63f87c9398762626e8.r2.cloudflarestorage.com/prosody/prosody-long";
      paths = [
        "/var/lib/prosody"
        "/etc/prosody/certs"
      ];
      exclude = [
        "/var/lib/prosody/**/archive"
        "/var/lib/prosody/**/muc_log"
      ];
      environmentFile = config.sops.templates."restic-r2.env".path;
      passwordFile = config.sops.secrets.restic_repository_password.path;
      initialize = true;
      pruneOpts = [
        "--keep-weekly 4"
        "--keep-monthly 6"
      ];
      backupPrepareCommand = ''
        while ! mkdir /run/prosody-backup.lock 2>/dev/null; do
          sleep 10
        done
        ${pkgs.systemd}/bin/systemctl stop prosody.service
      '';
      backupCleanupCommand = ''
        status=0
        ${pkgs.systemd}/bin/systemctl start prosody.service || status=$?
        rmdir /run/prosody-backup.lock
        exit "$status"
      '';
      timerConfig = {
        OnCalendar = "Sun *-*-* 04:00:00";
        RandomizedDelaySec = "1h";
        FixedRandomDelay = true;
        Persistent = true;
      };
    };
  };

  systemd.services.prosody.serviceConfig.EnvironmentFile = config.sops.templates."prosody.env".path;

  system.stateVersion = "26.05";
}
