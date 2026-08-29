{
  config,
  configurationName,
  lib,
  pkgs,
  ...
}:

let
  privateAddress = "10.77.3.16";
  pushClientConfig = builtins.fromJSON (builtins.readFile ../../packages/sygnal/client-config.json);
  sygnal = pkgs.callPackage ../../packages/sygnal/package.nix { };
  yaml = pkgs.formats.yaml { };
  sygnalConfig = yaml.generate "sygnal.yaml" {
    http = {
      bind_addresses = [ privateAddress ];
      port = 5000;
    };
    log = {
      setup = {
        version = 1;
        disable_existing_loggers = false;
        formatters.normal.format = "%(asctime)s %(levelname)-5s %(name)s %(message)s";
        handlers.stderr = {
          class = "logging.StreamHandler";
          formatter = "normal";
          stream = "ext://sys.stderr";
        };
        loggers = {
          "sygnal.access" = {
            handlers = [ ];
            level = "WARNING";
            propagate = false;
          };
          sygnal = {
            handlers = [ "stderr" ];
            level = "INFO";
            propagate = false;
          };
        };
        root = {
          handlers = [ "stderr" ];
          level = "WARNING";
        };
      };
      access.x_forwarded_for = true;
    };
    metrics = {
      prometheus.enabled = false;
      opentracing.enabled = false;
      sentry.enabled = false;
    };
    apps.${pushClientConfig.webPushAppID} = {
      type = "webpush";
      vapid_private_key = "/run/credentials/sygnal.service/vapid-private-key.pem";
      vapid_contact_email = "hostmaster@s3-odara.net";
      allowed_endpoints = [
        "*.push.apple.com"
        "fcm.googleapis.com"
        "updates.push.services.mozilla.com"
        "*.notify.windows.com"
      ];
      max_connections = 20;
      inflight_request_limit = 64;
      ttl = 900;
    };
  };
in
{
  assertions = [
    {
      assertion = builtins.stringLength pushClientConfig.vapidPublicKey == 87;
      message = "Sygnal VAPID public key must be an unpadded base64url P-256 key";
    }
    {
      assertion = pushClientConfig.webPushAppID != "";
      message = "Sygnal Web Push app ID must not be empty";
    }
  ];

  networking.hostName = configurationName;
  networking.useDHCP = true;
  networking.firewall.enable = false;

  users.groups.sygnal = { };
  users.users.sygnal = {
    isSystemUser = true;
    group = "sygnal";
    home = "/var/lib/sygnal";
  };

  systemd.services.sygnal = {
    description = "Matrix Sygnal Web Push gateway";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "sops-nix.service"
    ];
    serviceConfig = {
      User = "sygnal";
      Group = "sygnal";
      StateDirectory = "sygnal";
      WorkingDirectory = "/var/lib/sygnal";
      LoadCredential = [
        "vapid-private-key.pem:${config.sops.secrets.vapid_private_key.path}"
      ];
      Environment = [
        "PYTHONUNBUFFERED=1"
        "SYGNAL_CONF=${sygnalConfig}"
      ];
      ExecStartPre = pkgs.writeShellScript "verify-sygnal-vapid-key" ''
        set -euo pipefail
        actual=$(
          ${pkgs.openssl}/bin/openssl ec \
            -in "$CREDENTIALS_DIRECTORY/vapid-private-key.pem" \
            -pubout -outform DER 2>/dev/null \
            | ${pkgs.coreutils}/bin/tail -c 65 \
            | ${pkgs.coreutils}/bin/base64 -w 0 \
            | ${pkgs.coreutils}/bin/tr '/+' '_-' \
            | ${pkgs.coreutils}/bin/tr -d '='
        )
        expected=${lib.escapeShellArg pushClientConfig.vapidPublicKey}
        if [[ "$actual" != "$expected" ]]; then
          echo "VAPID private key does not match the published public key" >&2
          exit 1
        fi
      '';
      ExecStart = lib.getExe sygnal;
      ExecStartPost = pkgs.writeShellScript "check-sygnal-health" ''
        ${pkgs.curl}/bin/curl \
          --silent \
          --show-error \
          --fail \
          --retry 10 \
          --retry-all-errors \
          --retry-delay 1 \
          --max-time 2 \
          http://${privateAddress}:5000/health >/dev/null
      '';
      Restart = "on-failure";
      RestartSec = "5s";
      UMask = "0077";

      CapabilityBoundingSet = "";
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateMounts = true;
      PrivateTmp = true;
      ProcSubset = "pid";
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectProc = "invisible";
      ProtectSystem = "strict";
      ReadWritePaths = [ "/var/lib/sygnal" ];
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
        "~@resources"
      ];
    };
  };

  sops.secrets.vapid_private_key = {
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [ "sygnal.service" ];
  };

  system.stateVersion = "26.05";
}
