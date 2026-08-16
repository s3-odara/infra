{
  config,
  configurationName,
  lib,
  pkgs,
  ...
}:

{
  boot.isContainer = true;
  networking.hostName = configurationName;
  networking.useDHCP = true;
  networking.firewall.enable = false;

  services.prosody = {
    enable = true;
    package = pkgs.prosody.override {
      withCommunityModules = [
        "sasl_ssdp"
        "sasl2"
        "sasl2_bind2"
        "sasl2_sm"
      ];
    };
    checkConfig = true;
    admins = [ ];
    httpPorts = [ ];
    httpsPorts = [ 443 ];
    ssl = {
      cert = "/var/lib/acme/xmpp.odarah.org/fullchain.pem";
      key = "/var/lib/acme/xmpp.odarah.org/key.pem";
    };
    allowRegistration = true;
    authentication = "internal_hashed";
    c2sRequireEncryption = true;
    s2sRequireEncryption = true;
    s2sSecureAuth = true;

    virtualHosts = {
      main = {
        enabled = true;
        domain = "xmpp.odarah.org";
        extraConfig = ''
          admins = { "admin@xmpp.odarah.org" }
          custom_roles = {
            {
              name = "xmpp:inviter";
              inherits = { "prosody:member" };
              allow = {
                "adhoc:urn:xmpp:invite#create-account";
                ":invite-users";
              };
            };
          }
        '';
      };
    };

    muc = [
      {
        domain = "conference.xmpp.odarah.org";
        restrictRoomCreation = "local";
        roomDefaultPublic = false;
        roomDefaultMembersOnly = true;

        extraConfig = ''
          admins = { "admin@xmpp.odarah.org" }
          muc_room_default_persistent = true
          muc_log_expires_after = "2w"
        '';
      }
    ];

    httpFileShare = {
      domain = "share.xmpp.odarah.org";
      size_limit = 100 * 1024 * 1024;
      daily_quota = 1024 * 1024 * 1024;
      global_quota = 10 * 1024 * 1024 * 1024;
      expires_after = "1w";
      access = [
        "xmpp.odarah.org"
      ];
    };

    modules = {
      admin_adhoc = true;
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
      c2s_direct_tls_ports = { 5223 }
      tls_server_end_point_hash = "auto"
      limits = {
        c2s = { rate = "10kb/s" };
        s2sin = { rate = "30kb/s" };
      }
      storage = "internal"
      archive_expires_after = "2w"
      registration_invite_only = true
      invite_expiry = 86400
      allow_user_invites = false
      turn_external_host = "xmpp.odarah.org"
      turn_external_secret = "$TURN_EXTERNAL_SECRET"
      turn_external_tls_port = 5349
    '';
  };

  services.coturn = {
    enable = true;
    listening-ips = [ "10.77.2.10" ];
    relay-ips = [ "10.77.2.10" ];
    min-port = 49160;
    max-port = 49200;
    realm = "xmpp.odarah.org";
    use-auth-secret = true;
    static-auth-secret-file = "/run/credentials/coturn.service/turn-secret";
    cert = "/run/credentials/coturn.service/tls-cert";
    pkey = "/run/credentials/coturn.service/tls-key";
    no-cli = true;
    no-tcp = true;
    no-dtls = true;
    no-tcp-relay = true;
    extraConfig = ''
      external-ip=133.117.77.64/10.77.2.10
      no-multicast-peers
      denied-peer-ip=10.0.0.0-10.255.255.255
      denied-peer-ip=172.16.0.0-172.31.255.255
      denied-peer-ip=192.168.0.0-192.168.255.255
    '';
  };

  # ACME
  security.acme = {
    acceptTerms = true;
    defaults.email = "hostmaster@s3-odara.net";
    certs."xmpp.odarah.org" = {
      profile = "shortlived";
      validMinDays = 4;
      renewInterval = "*-*-* 00,06,12,18:00:00";
      renewJitter = "1h";
      extraDomainNames = [
        "conference.xmpp.odarah.org"
        "share.xmpp.odarah.org"
      ];
      group = "prosody";
      listenHTTP = "0.0.0.0:80";
      reloadServices = [
        "coturn.service"
        "prosody.service"
      ];
    };
  };

  systemd.timers."acme-renew-xmpp.odarah.org".timerConfig.AccuracySec = lib.mkForce "15min";

  systemd.services."acme-order-renew-xmpp.odarah.org" = {
    serviceConfig = {
      Restart = "on-failure";
      RestartSteps = 4;
      RestartMaxDelaySec = "6h";
      LoadCredential = [ "ntfy-topic:${config.sops.secrets.ntfy_topic.path}" ];
      ExecStopPost = pkgs.writeShellScript "notify-acme-failure" ''
        if [ "$SERVICE_RESULT" != "success" ]; then
          topic="$(<"$CREDENTIALS_DIRECTORY/ntfy-topic")"
          ${pkgs.curl}/bin/curl \
            --silent \
            --show-error \
            --fail \
            --max-time 15 \
            --data-binary 'TLS証明書更新が失敗しました。' \
            "https://ntfy.sh/$topic" || true
        fi
      '';
    };

    unitConfig.StartLimitIntervalSec = 0;
  };

  sops = {
    secrets = {
      turn_external_secret.restartUnits = [ "coturn.service" ];
      ntfy_topic = { };
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
        restartUnits = [ "prosody.service" ];
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
      paths = [ "/var/lib/prosody" ];
      exclude = [ "/var/lib/prosody/share%2exmpp%2eodarah%2eorg" ];
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
      paths = [ "/var/lib/prosody" ];
      exclude = [
        "/var/lib/prosody/**/archive"
        "/var/lib/prosody/**/muc_log"
        "/var/lib/prosody/share%2exmpp%2eodarah%2eorg"
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

  systemd.services.coturn = {
    after = [ "acme-xmpp.odarah.org.service" ];
    wants = [ "acme-xmpp.odarah.org.service" ];
    serviceConfig.LoadCredential = [
      "turn-secret:${config.sops.secrets.turn_external_secret.path}"
      "tls-cert:/var/lib/acme/xmpp.odarah.org/fullchain.pem"
      "tls-key:/var/lib/acme/xmpp.odarah.org/key.pem"
    ];
  };

  systemd.services.prosody = {
    after = [ "acme-xmpp.odarah.org.service" ];
    wants = [ "acme-xmpp.odarah.org.service" ];
    preStart = lib.mkAfter ''
      ${lib.getExe' config.services.prosody.package "prosodyctl"} \
        --config /run/prosody/prosody.cfg.lua \
        check config
    '';
    serviceConfig = {
      EnvironmentFile = config.sops.templates."prosody.env".path;
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
    };
  };

  system.stateVersion = "26.05";
}
