{
  config,
  configurationName,
  lib,
  pkgs,
  ...
}:

let
  backupFailureNotifier = pkgs.writeShellScript "notify-backup-failure" ''
    topic="$(<"$CREDENTIALS_DIRECTORY/ntfy-topic")"
    ${pkgs.curl}/bin/curl \
      --silent \
      --show-error \
      --fail \
      --max-time 15 \
      --header "Priority: 5" \
      --header "Tags: warning" \
      --data-binary "Prosody backup failed" \
      "https://ntfy.sh/$topic"
  '';
in
{
  networking.hostName = configurationName;
  networking.useDHCP = true;
  networking.firewall.enable = false;

  services.prosody = {
    enable = true;
    package =
      (pkgs.prosody.override {
        withCommunityModules = [
          "sasl_ssdp"
          "sasl2"
          "sasl2_bind2"
          "sasl2_sm"
          "sasl2_fast"
          "csi_grace_period"
          "invites_page"
          "invites_register_web"
          "register_apps"
          "password_policy"
          "cloud_notify_encrypted"
        ];
      }).overrideAttrs
        (old: {
          postInstall = (old.postInstall or "") + ''
            invites_page="$out/lib/prosody/modules/mod_invites_page"
            invites_register_web="$out/lib/prosody/modules/mod_invites_register_web"
            register_apps="$out/lib/prosody/modules/mod_register_apps/mod_register_apps.lua"
            http_server="$out/lib/prosody/net/http/server.lua"

            chmod -R u+w "$invites_page" "$invites_register_web" "$(dirname "$register_apps")"
            chmod u+w "$http_server"
            install -m 0644 ${./invites/invite.html} "$invites_page/html/invite.html"
            install -m 0644 ${./invites/client.html} "$invites_page/html/client.html"
            install -m 0644 ${./invites/invite_invalid.html} "$invites_page/html/invite_invalid.html"
            install -m 0644 ${./invites/static/style.css} "$invites_page/static/style.css"
            install -m 0644 ${./invites/static/qr-only.js} "$invites_page/static/qr-only.js"
            install -m 0644 ${./invites/register.html} "$invites_register_web/html/register.html"
            install -m 0644 ${./invites/register_error.html} "$invites_register_web/html/register_error.html"
            install -m 0644 ${./invites/register_success.html} "$invites_register_web/html/register_success.html"
            install -m 0644 ${./invites/register_success_setup.html} "$invites_register_web/html/register_success_setup.html"

            substituteInPlace "$invites_page/mod_invites_page.lua" \
              --replace-fail 'js  = "application/javascript";' 'js  = "application/javascript"; css = "text/css";'
            substituteInPlace "$register_apps" \
              --replace-fail 'platforms = { "Linux" };' 'platforms = { "Linux", "OpenBSD" };' \
              --replace-fail 'platforms = { "Windows", "Linux", "macOS" };' 'platforms = { "Windows", "Linux", "macOS", "OpenBSD" };' \
              --replace-fail 'magic_link_format = "{app.link!}&referrer={invite.uri}";' "" \
              --replace-fail \
                'text  = [[A modern open-source chat client for Mac. It is easy to use and has a clean user interface.]];' \
                $'id = "monal-macos";\n\t\ttext  = [[A modern open-source chat client for Mac. It is easy to use and has a clean user interface.]];'

            patch --batch --forward -d "$invites_page" -p1 < ${./invites/patches/invites-page-security.patch}
            patch --batch --forward -d "$invites_register_web" -p1 < ${./invites/patches/invites-register-web-security.patch}
            patch --batch --forward -d "$(dirname "$http_server")" -p1 < ${./invites/patches/http-redact-query.patch}
            # The HTTP server's async-runner fallback writes a fixed header set,
            # so serialize the value installed by mod_http_hsts there as well.
            substituteInPlace "$http_server" \
              --replace-fail \
                $'\t\tX-Content-Type-Options: nosniff\\r\\n\\z\n\t\tContent-Type: " .. response.headers.content_type' \
                $'\t\tX-Content-Type-Options: nosniff\\r\\n\\z\n\t\tStrict-Transport-Security: " .. response.headers.strict_transport_security .. "\\r\\n\\z\n\t\tContent-Type: " .. response.headers.content_type'
          '';
        });
    checkConfig = true;
    extraPluginPaths = [
      (pkgs.linkFarm "prosody-http-hsts-module" [
        {
          name = "mod_http_hsts.lua";
          path = ./mod_http_hsts.lua;
        }
      ])
    ];
    admins = [ ];
    httpPorts = [ ];
    httpsPorts = [ ];
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
          password_hash = "SHA-256"
          default_iteration_count = 600000
          admins = { "admin@xmpp.odarah.org" }
          contact_info = {
            admin = { "xmpp:odara@xmpp.odarah.org" };
            abuse = { "xmpp:odara@xmpp.odarah.org" };
          }
          site_name = "odarah.org XMPP"
          -- net_multiplex owns port 443, so no active https service exists for
          -- module:http_url() to discover; without this it returns http://disabled.invalid/
          http_external_url = "https://xmpp.odarah.org/"
          invites_page = "https://xmpp.odarah.org/invites_page?{invite.token}"
          password_policy = {
            length = 20;
            exclude_username = true;
          }
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
      # Without this, upload slot URLs point at http://disabled.invalid/ because
      # net_multiplex owns port 443 and portmanager sees no active https service
      http_external_url = "https://share.xmpp.odarah.org/";
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
      server_contact_info = true;
      websocket = true;
    };

    extraModules = [
      "account_activity"
      "csi_simple"
      "invites"
      "invites_adhoc"
      "invites_register"
      "http_hsts"
      "net_multiplex"
      "turn_external"
    ];

    extraConfig = ''
      ssl_ports = { 443 }
      c2s_direct_tls_ports = { 5223 }
      s2s_direct_tls_ports = { 5270 }
      tls_server_end_point_hash = "auto"
      limits = {
        c2s = { rate = "10kb/s"; max_connections_per_ip = 30 };
        s2sin = { rate = "30kb/s"; max_connections_per_ip = 20 };
      }
      disabled_sasl_mechanisms = { "PLAIN", "LOGIN", "DIGEST-MD5" };
      c2s_timeout = 60;
      storage = "internal"
      archive_expires_after = "2w"
      registration_invite_only = true
      invite_expiry = 86400
      allow_user_invites = false
      turn_external_host = "turn.odarah.org"
      turn_external_secret = ENV_TURN_EXTERNAL_SECRET
      turn_external_tls_port = 443
      -- used only by prosody check dns
      external_addresses = { "15.235.184.173" }
    '';
  };

  # ACME
  security.acme = {
    acceptTerms = true;
    defaults.email = "hostmaster@s3-odara.net";
    certs."xmpp.odarah.org" = {
      profile = "shortlived";
      renewInterval = "*-*-* 00,06,12,18:00:00";
      renewJitter = "1h";
      extraDomainNames = [
        "conference.xmpp.odarah.org"
        "share.xmpp.odarah.org"
      ];
      group = "prosody";
      listenHTTP = "0.0.0.0:80";
      reloadServices = [ "prosody.service" ];
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
            --data-binary 'xmpp のTLS証明書更新が失敗しました。' \
            "https://ntfy.sh/$topic" || true
        fi
      '';
    };

    unitConfig.StartLimitIntervalSec = 0;
  };

  sops = {
    secrets = {
      turn_external_secret = { };
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
        "--keep-weekly 8"
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

  systemd.services."backup-failure-notify@".serviceConfig = {
    Type = "oneshot";
    LoadCredential = [ "ntfy-topic:${config.sops.secrets.ntfy_topic.path}" ];
    ExecStart = backupFailureNotifier;
  };
  systemd.services."restic-backups-prosody-short".unitConfig.OnFailure =
    "backup-failure-notify@%n.service";
  systemd.services."restic-backups-prosody-long".unitConfig.OnFailure =
    "backup-failure-notify@%n.service";

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
