{
  config,
  configurationName,
  lib,
  pkgs,
  utils,
  ...
}:

let
  privateAddress = "10.77.3.15";
  turnHost = "turn.odarah.org";
  livekitSettings = {
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
    webhook = {
      api_key = config.sops.placeholder.livekit_api_key;
      urls = [ "https://matrix.odarah.org/_tuwunel/livekit/webhook" ];
    };
  };
  acmeDnsEnvironment = pkgs.writeText "acme-rfc2136.env" ''
    DNSUPDATE_NAMESERVER=10.77.3.11:53
    DNSUPDATE_TSIG_KEY=rtc.
    DNSUPDATE_TSIG_ALGORITHM=hmac-sha256.
    DNSUPDATE_TTL=60
    DNSUPDATE_SEQUENCE_INTERVAL=2
    DNSUPDATE_ZONES=_acme-challenge.odarah.org.
  '';
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

  services.livekit = {
    enable = true;
    package = pkgs.livekit;
    keyFile = config.sops.templates."livekit-key-file".path;
    openFirewall = false;
    redis.createLocally = false;
  };

  systemd.services.livekit.serviceConfig = {
    LoadCredential = [
      "turn-secret:${config.sops.secrets.turn_external_secret.path}"
      "livekit-config:${config.sops.templates."livekit-config.json".path}"
    ];
    ExecStart = lib.mkForce (
      utils.escapeSystemdExecArgs [
        (lib.getExe config.services.livekit.package)
        "--config=/run/credentials/livekit.service/livekit-config"
        "--key-file=/run/credentials/livekit.service/livekit-secrets"
      ]
    );
  };

  security.acme = {
    acceptTerms = true;
    defaults.email = "hostmaster@s3-odara.net";
    certs.${turnHost} = {
      dnsProvider = "rfc2136";
      environmentFile = acmeDnsEnvironment;
      credentialFiles.DNSUPDATE_TSIG_SECRET_FILE = config.sops.secrets.rtc_tsig_secret.path;
      profile = "shortlived";
      extraLegoRenewFlags = [ "--reuse-key" ];
      renewInterval = "*-*-* 00,06,12,18:00:00";
      renewJitter = "1h";
      # Refresh the systemd TLS credentials before eturnal reloads its PEM file.
      reloadServices = [ "eturnal.service" ];
    };
  };

  systemd.timers."acme-renew-${turnHost}".timerConfig.AccuracySec = lib.mkForce "1s";
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
            --output /dev/null \
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
      rtc_tsig_secret = { };
      livekit_api_key = { };
      livekit_api_secret = { };
      ntfy_topic = { };
      turn_external_secret.restartUnits = [
        "eturnal.service"
        "livekit.service"
      ];
    };
    templates = {
      "livekit-key-file" = {
        content = "${config.sops.placeholder.livekit_api_key}: ${config.sops.placeholder.livekit_api_secret}\n";
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ "livekit.service" ];
      };
      "livekit-config.json" = {
        content = builtins.toJSON livekitSettings;
        owner = "root";
        group = "root";
        mode = "0400";
        restartUnits = [ "livekit.service" ];
      };
    };
  };

  system.stateVersion = "26.05";
}
