{
  config,
  configurationName,
  pkgs,
  ...
}:

let
  forwardZone = ./zones/odarah.org.zone;
  reverseZone = ./zones/173.184.235.15.in-addr.arpa.zone;
  acmeZone = ./zones/_acme-challenge.odarah.org.zone;
  backupDirectory = "/var/lib/knot/backup";
  backupFailureNotifier = pkgs.writeShellScript "notify-backup-failure" ''
    topic="$(<"$CREDENTIALS_DIRECTORY/ntfy-topic")"
    ${pkgs.curl}/bin/curl \
      --silent \
      --show-error \
      --fail \
      --output /dev/null \
      --max-time 15 \
      --header "Priority: 5" \
      --header "Tags: warning" \
      --data-binary "Knot backup failed" \
      "https://ntfy.sh/$topic"
  '';
  dnssecHealthCheck = pkgs.writeShellScript "check-knot-dnssec-health" ''
    set -euo pipefail

    for zone in odarah.org. _acme-challenge.odarah.org.; do
      ${pkgs.knot-dns}/bin/knotc --mono zone-read "$zone" |
        ${pkgs.gnused}/bin/sed 's/^\[[^]]*\] //' |
        ${pkgs.ldns.examples}/bin/ldns-verify-zone -e P4D
    done
  '';
  dnssecFailureNotifier = pkgs.writeShellScript "notify-dnssec-failure" ''
    topic="$(<"$CREDENTIALS_DIRECTORY/ntfy-topic")"
    ${pkgs.curl}/bin/curl \
      --silent \
      --show-error \
      --fail \
      --output /dev/null \
      --max-time 15 \
      --header "Priority: 5" \
      --header "Tags: warning" \
      --data-binary "Knot DNSSEC signing health check failed" \
      "https://ntfy.sh/$topic"
  '';

  matrixAcmeUpdateOwners = [
    "_acme-challenge.odarah.org."
    "matrix._acme-challenge.odarah.org."
    "cinny-matrix._acme-challenge.odarah.org."
    "element-matrix._acme-challenge.odarah.org."
    "rtc-matrix._acme-challenge.odarah.org."
    "sable-matrix._acme-challenge.odarah.org."
    "push-matrix._acme-challenge.odarah.org."
  ];
  xmppAcmeUpdateOwners = [
    "xmpp._acme-challenge.odarah.org."
    "conference-xmpp._acme-challenge.odarah.org."
    "share-xmpp._acme-challenge.odarah.org."
  ];
  turnAcmeUpdateOwners = [ "turn._acme-challenge.odarah.org." ];
in
{
  networking.hostName = configurationName;
  networking.useDHCP = true;
  networking.firewall.enable = false;

  sops = {
    secrets = {
      nginx_tsig_secret = { };
      prosody_tsig_secret = { };
      rtc_tsig_secret = { };
      ntfy_topic = { };
      r2_access_key_id = { };
      r2_secret_access_key = { };
      restic_repository_password = { };
    };
    templates = {
      "knot-acme-tsig.conf" = {
        content = ''
          key:
            - id: nginx.
              algorithm: hmac-sha256
              secret: ${config.sops.placeholder.nginx_tsig_secret}
            - id: prosody.
              algorithm: hmac-sha256
              secret: ${config.sops.placeholder.prosody_tsig_secret}
            - id: rtc.
              algorithm: hmac-sha256
              secret: ${config.sops.placeholder.rtc_tsig_secret}
        '';
        owner = "knot";
        group = "knot";
        mode = "0400";
        restartUnits = [ "knot.service" ];
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

  services.knot = {
    enable = true;
    keyFiles = [ config.sops.templates."knot-acme-tsig.conf".path ];

    settings = {
      server = {
        listen = [ "0.0.0.0@53" ];
        identity = "";
        version = "";
        nsid = "";
        udp-workers = 1;
        tcp-workers = 1;
        background-workers = 1;
        tcp-idle-timeout = 10;
        tcp-io-timeout = 1000;
        tcp-max-clients = 100;
        udp-max-payload = 1232;
        edns-client-subnet = false;
        automatic-acl = false;
      };

      database.storage = "/var/lib/knot";

      log.syslog.any = "info";

      policy.odarah = {
        single-type-signing = true;
        algorithm = "ed25519";
        ksk-lifetime = 0;
        dnskey-ttl = "1h";
        zone-max-ttl = "1h";
        propagation-delay = "1h";
        rrsig-lifetime = "6d";
        rrsig-refresh = "5d";
        nsec3 = false;
        cds-cdnskey-publish = "none";
      };

      acl = {
        nginx = {
          address = [ "10.77.3.13" ];
          key = [ "nginx." ];
          action = [ "update" ];
          update-type = [ "TXT" ];
          update-owner = "name";
          update-owner-match = "equal";
          update-owner-name = matrixAcmeUpdateOwners;
        };
        prosody = {
          address = [ "10.77.3.10" ];
          key = [ "prosody." ];
          action = [ "update" ];
          update-type = [ "TXT" ];
          update-owner = "name";
          update-owner-match = "equal";
          update-owner-name = xmppAcmeUpdateOwners;
        };
        rtc = {
          address = [ "10.77.3.15" ];
          key = [ "rtc." ];
          action = [ "update" ];
          update-type = [ "TXT" ];
          update-owner = "name";
          update-owner-match = "equal";
          update-owner-name = turnAcmeUpdateOwners;
        };
      };

      mod-rrl.default = {
        rate-limit = 200;
        instant-limit = 500;
        slip = 2;
        table-size = 1000000;
        log-period = 30000;
      };

      template.default = {
        semantic-checks = true;
        zonefile-sync = -1;
        zonefile-load = "difference-no-serial";
        journal-content = "all";
        serial-policy = "increment";
        global-module = [
          "mod-cookies"
          "mod-rrl/default"
        ];
      };

      zone = {
        "odarah.org." = {
          file = forwardZone;
          dnssec-signing = true;
          dnssec-policy = "odarah";
        };

        "_acme-challenge.odarah.org." = {
          file = acmeZone;
          zonefile-skip = [ "TXT" ];
          acl = [
            "nginx"
            "prosody"
            "rtc"
          ];
          dnssec-signing = true;
          dnssec-policy = "odarah";
        };

        "173.184.235.15.in-addr.arpa.".file = reverseZone;
      };
    };
  };

  services.restic.backups.knot = {
    repository = "s3:https://6ecd930c8cd4dc63f87c9398762626e8.r2.cloudflarestorage.com/knot/restic";
    paths = [ backupDirectory ];
    environmentFile = config.sops.templates."restic-r2.env".path;
    passwordFile = config.sops.secrets.restic_repository_password.path;
    initialize = true;
    pruneOpts = [
      "--keep-daily 14"
      "--keep-weekly 8"
      "--keep-monthly 6"
    ];
    backupPrepareCommand = ''
      ${pkgs.knot-dns}/bin/knotc -b -f zone-backup \
        +backupdir ${backupDirectory} \
        +zonefile \
        +journal \
        +timers \
        +kaspdb
    '';
    timerConfig = {
      OnCalendar = "*-*-* 04:15:00 Asia/Tokyo";
      RandomizedDelaySec = "15m";
      FixedRandomDelay = true;
      Persistent = true;
    };
  };

  systemd.services = {
    # keyFiles contain a runtime SOPS template, so the module cannot validate
    # the complete configuration in the Nix build sandbox. Validate it before
    # start.
    knot.serviceConfig.ExecStartPre = "${pkgs.knot-dns}/bin/knotc --config=/etc/knot/knot.conf conf-check";

    "backup-failure-notify@".serviceConfig = {
      Type = "oneshot";
      LoadCredential = [ "ntfy-topic:${config.sops.secrets.ntfy_topic.path}" ];
      ExecStart = backupFailureNotifier;
    };

    "restic-backups-knot" = {
      wants = [ "knot.service" ];
      after = [ "knot.service" ];
      unitConfig.OnFailure = "backup-failure-notify@%n.service";
    };

    knot-dnssec-health-check = {
      wants = [ "knot.service" ];
      after = [ "knot.service" ];
      unitConfig.OnFailure = "knot-dnssec-failure-notify.service";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = dnssecHealthCheck;
      };
    };

    knot-dnssec-failure-notify.serviceConfig = {
      Type = "oneshot";
      LoadCredential = [ "ntfy-topic:${config.sops.secrets.ntfy_topic.path}" ];
      ExecStart = dnssecFailureNotifier;
    };
  };

  systemd.timers.knot-dnssec-health-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 00/6:00:00";
      RandomizedDelaySec = "15m";
      Persistent = true;
    };
  };

  system.stateVersion = "26.05";
}
