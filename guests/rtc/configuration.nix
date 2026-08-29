{
  config,
  configurationName,
  lib,
  pkgs,
  ...
}:

let
  privateAddress = "10.77.3.15";
  turnHost = "turn.odarah.org";
in
{
  imports = [ ./eturnal.nix ];

  networking.hostName = configurationName;
  networking.useDHCP = true;
  networking.firewall.enable = false;
  networking.hosts."10.77.3.13" = [
    "matrix.odarah.org"
    "rtc.matrix.odarah.org"
  ];

  users.groups.lk-jwt-service = { };
  users.users.lk-jwt-service = {
    isSystemUser = true;
    group = "lk-jwt-service";
  };

  services.livekit = {
    enable = true;
    package = pkgs.livekit;
    keyFile = config.sops.templates."livekit-key-file".path;
    openFirewall = false;
    redis.createLocally = false;
    settings = {
      port = 7880;
      bind_addresses = [ privateAddress ];
      rtc = {
        tcp_port = 7881;
        port_range_start = 50100;
        port_range_end = 50200;
        use_external_ip = true;
        external_ip_only = true;
        enable_loopback_candidate = false;
        turn_servers = [
          {
            host = turnHost;
            port = 3478;
            protocol = "udp";
            secret_file = "/run/credentials/livekit.service/turn-secret";
          }
          {
            host = turnHost;
            port = 443;
            protocol = "tls";
            secret_file = "/run/credentials/livekit.service/turn-secret";
          }
        ];
      };
      room.auto_create = false;
    };
  };

  systemd.services.livekit.serviceConfig.LoadCredential = [
    "turn-secret:${config.sops.secrets.turn_external_secret.path}"
  ];

  systemd.services.lk-jwt-service = {
    description = "MatrixRTC LiveKit JWT authorization service";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [
      "livekit.service"
      "network-online.target"
    ];
    serviceConfig = {
      User = "lk-jwt-service";
      Group = "lk-jwt-service";
      LoadCredential = [ "livekit-key:${config.sops.templates."livekit-key-file".path}" ];
      Environment = [
        "LIVEKIT_JWT_BIND=${privateAddress}:8081"
        "LIVEKIT_URL=wss://rtc.matrix.odarah.org"
        "LIVEKIT_KEY_FILE=%d/livekit-key"
        "LIVEKIT_FULL_ACCESS_HOMESERVERS=matrix.odarah.org"
      ];
      ExecStart = lib.getExe pkgs.lk-jwt-service;
      Restart = "on-failure";
      RestartSec = "5s";
      UMask = "0077";

      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateMounts = true;
      PrivateTmp = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectSystem = "strict";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
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

  security.acme = {
    acceptTerms = true;
    defaults.email = "hostmaster@s3-odara.net";
    certs.${turnHost} = {
      profile = "shortlived";
      renewInterval = "*-*-* 00,06,12,18:00:00";
      renewJitter = "1h";
      listenHTTP = "0.0.0.0:80";
      # Refresh the systemd TLS credentials before eturnal reloads its PEM file.
      reloadServices = [ "eturnal.service" ];
    };
  };

  systemd.timers."acme-renew-${turnHost}".timerConfig.AccuracySec = lib.mkForce "15min";
  systemd.services."acme-order-renew-${turnHost}" = {
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
            --header "Priority: 5" \
            --header "Tags: warning" \
            --data-binary 'turn のTLS証明書更新が失敗しました。' \
            "https://ntfy.sh/$topic" || true
        fi
      '';
    };

    unitConfig.StartLimitIntervalSec = 0;
  };

  sops = {
    secrets = {
      livekit_api_key = { };
      livekit_api_secret = { };
      ntfy_topic = { };
      turn_external_secret.restartUnits = [
        "eturnal.service"
        "livekit.service"
      ];
    };
    templates."livekit-key-file" = {
      content = "${config.sops.placeholder.livekit_api_key}: ${config.sops.placeholder.livekit_api_secret}\n";
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [
        "livekit.service"
        "lk-jwt-service.service"
      ];
    };
  };

  system.stateVersion = "26.05";
}
