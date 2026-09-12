{
  config,
  configurationName,
  lib,
  pkgs,
  ...
}:

let
  inviteBot = pkgs.callPackage ../../packages/matrix-invite-bot/package.nix { };
  registrationToken = "/var/lib/tuwunel/registration-token";
  backupDirectory = "/var/lib/tuwunel-backups";
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
      --data-binary "Tuwunel backup failed" \
      "https://ntfy.sh/$topic"
  '';
in
{
  networking.hostName = configurationName;
  networking.useDHCP = true;
  networking.firewall.enable = false;

  environment.systemPackages = [
    pkgs.curl
    pkgs.jq
  ];

  users.groups.matrix-invite-bot = { };
  users.users.matrix-invite-bot = {
    isSystemUser = true;
    group = "matrix-invite-bot";
    home = "/var/lib/matrix-invite-bot";
  };

  services.matrix-tuwunel = {
    enable = true;
    settings.global = {
      server_name = "matrix.odarah.org";
      address = [
        "127.0.0.1"
        "10.77.3.14"
      ];
      port = [ 8008 ];
      ip_source = "rightmost_x_forwarded_for";
      ip_lookup_strategy = 1;
      max_request_size = 16 * 1024 * 1024;
      max_response_size = 128 * 1024 * 1024;
      new_user_displayname_suffix = "";
      allow_registration = true;
      registration_token_file = registrationToken;
      oidc_native_auth = true;
      oidc_require_pkce = true;
      oidc_require_device_scope = false;
      oidc_rc_per_second = 1;
      oidc_rc_burst_count = 20;
      refresh_token_ttl = 90 * 24 * 60 * 60;
      refresh_token_idle_only = true;
      refresh_token_hard_logout = false;
      allow_encryption = true;
      encryption_enabled_by_default_for_room_type = "invite";
      grant_admin_to_first_user = false;
      admin_escape_commands = false;
      federate_admin_room = false;
      allow_unlisted_room_search_by_id = false;
      require_auth_for_profile_requests = true;
      cache_capacity_modifier = 0.5;
      db_cache_capacity_mb = 128;
      db_write_buffer_capacity_mb = 52;
      rocksdb_allow_fallocate = false;
      database_backup_path = backupDirectory;
      database_backups_to_keep = 2;
      admin_signal_execute = [
        "server backup-database"
        "media delete-range 7d --older-than"
      ];
      turn_uris = [
        "turn:turn.odarah.org:3478?transport=udp"
        "turn:turn.odarah.org:3478?transport=tcp"
        "turns:turn.odarah.org:443?transport=tcp"
        "turns:turn.odarah.org:5349?transport=tcp"
      ];
      turn_ttl = 86400;
      turn_secret_file = config.sops.secrets.turn_external_secret.path;
      well_known.client = "https://matrix.odarah.org";
      well_known.livekit_url = "https://rtc.matrix.odarah.org";
      error_on_unknown_config_opts = true;
    };
  };

  # The module creates /var/lib/tuwunel before start and runs this as its user.
  systemd.services.tuwunel = {
    serviceConfig = {
      StateDirectory = [ "tuwunel-backups" ];
      ExecStartPre = pkgs.writeShellScript "tuwunel-registration-token" ''
        set -eu
        if ! test -s ${lib.escapeShellArg registrationToken}; then
          umask 077
          ${lib.getExe pkgs.openssl} rand -hex 32 > ${lib.escapeShellArg "${registrationToken}.new"}
          ${pkgs.coreutils}/bin/chmod 0600 ${lib.escapeShellArg "${registrationToken}.new"}
          ${pkgs.coreutils}/bin/mv ${lib.escapeShellArg "${registrationToken}.new"} ${lib.escapeShellArg registrationToken}
        fi
      '';
    };
  };

  systemd.services.tuwunel-online-backup = {
    description = "Trigger a Tuwunel online database backup";
    requires = [ "tuwunel.service" ];
    after = [ "tuwunel.service" ];
    unitConfig.OnFailure = "backup-failure-notify@%n.service";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl kill --kill-whom=main --signal=SIGUSR2 tuwunel.service";
    };
  };

  systemd.timers.tuwunel-online-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 05:30:00 Asia/Tokyo";
      RandomizedDelaySec = "15m";
      FixedRandomDelay = true;
      Persistent = false;
    };
  };

  sops = {
    secrets = {
      turn_external_secret = {
        owner = "tuwunel";
        group = "tuwunel";
        mode = "0400";
        restartUnits = [ "tuwunel.service" ];
      };
      ntfy_topic = { };
      r2_access_key_id = { };
      r2_secret_access_key = { };
      restic_repository_password = { };
      matrix_invite_bot_device_id = { };
      matrix_invite_bot_access_token = { };
      guest_registration_admin_token = { };
      guest_registration_sentinel = { };
    };

    templates = {
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

      "matrix-invite-bot.env" = {
        content = ''
          MATRIX_USER_ID=@invite-bot:matrix.odarah.org
          MATRIX_DEVICE_ID=${config.sops.placeholder.matrix_invite_bot_device_id}
          MATRIX_ACCESS_TOKEN=${config.sops.placeholder.matrix_invite_bot_access_token}
          GUEST_ADMIN_ACCESS_TOKEN=${config.sops.placeholder.guest_registration_admin_token}
          GUEST_SENTINEL_TOKEN=${config.sops.placeholder.guest_registration_sentinel}
        '';
        owner = "matrix-invite-bot";
        group = "matrix-invite-bot";
        mode = "0400";
        restartUnits = [ "matrix-invite-bot.service" ];
      };
    };
  };

  services.restic.backups.tuwunel = {
    repository = "s3:https://6ecd930c8cd4dc63f87c9398762626e8.r2.cloudflarestorage.com/tuwunel/restic";
    paths = [
      backupDirectory
      "/var/lib/tuwunel/media"
      registrationToken
      "/var/lib/matrix-invite-bot"
    ];
    environmentFile = config.sops.templates."restic-r2.env".path;
    passwordFile = config.sops.secrets.restic_repository_password.path;
    initialize = true;
    pruneOpts = [
      "--keep-daily 14"
      "--keep-weekly 8"
    ];
    backupPrepareCommand = ''
      ${pkgs.systemd}/bin/systemctl stop matrix-invite-bot.service
    '';
    backupCleanupCommand = ''
      ${pkgs.systemd}/bin/systemctl start matrix-invite-bot.service
    '';
    timerConfig = {
      OnCalendar = "*-*-* 04:30:00 Asia/Tokyo";
      RandomizedDelaySec = "15m";
      FixedRandomDelay = true;
      Persistent = false;
    };
  };

  systemd.services."backup-failure-notify@".serviceConfig = {
    Type = "oneshot";
    LoadCredential = [ "ntfy-topic:${config.sops.secrets.ntfy_topic.path}" ];
    ExecStart = backupFailureNotifier;
  };
  systemd.services."restic-backups-tuwunel".unitConfig.OnFailure = "backup-failure-notify@%n.service";
  systemd.services.tuwunel-monthly-backup = {
    description = "Create an encrypted monthly Tuwunel backup";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    unitConfig.OnFailure = "backup-failure-notify@%n.service";
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "10m";
      EnvironmentFile = config.sops.templates."restic-r2.env".path;
    };
    preStart = ''
      ${pkgs.systemd}/bin/systemctl stop matrix-invite-bot.service
    '';
    script = ''
      set -o pipefail
      month="$(TZ=Asia/Tokyo ${pkgs.coreutils}/bin/date +%Y-%m)"
      timestamp="$(${pkgs.coreutils}/bin/date --utc +%Y%m%dT%H%M%SZ)"
      recipient="$(${pkgs.age}/bin/age-keygen -y ${config.sops.age.keyFile})"
      export RCLONE_CONFIG_R2_TYPE=s3
      export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
      export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
      export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
      export RCLONE_CONFIG_R2_ENDPOINT=https://6ecd930c8cd4dc63f87c9398762626e8.r2.cloudflarestorage.com
      export RCLONE_CONFIG_R2_REGION=auto
      export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

      ${pkgs.gnutar}/bin/tar \
        --create --file=- --directory=/ --numeric-owner --acls --xattrs --sparse \
        var/lib/tuwunel-backups \
        var/lib/tuwunel/registration-token \
        var/lib/matrix-invite-bot \
        | ${pkgs.zstd}/bin/zstd --quiet --threads=1 --stdout \
        | ${lib.getExe pkgs.age} --encrypt --recipient "$recipient" \
        | ${lib.getExe pkgs.rclone} --config /dev/null rcat \
          "r2:tuwunel/archive/$month/$timestamp.tar.zst.age"
    '';
    postStop = ''
      ${pkgs.systemd}/bin/systemctl start matrix-invite-bot.service
    '';
  };

  systemd.timers.tuwunel-monthly-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-01 06:30:00 Asia/Tokyo";
      RandomizedDelaySec = "15m";
      FixedRandomDelay = true;
      Persistent = true;
    };
  };

  systemd.services.matrix-invite-bot = {
    description = "Encrypted Matrix registration invite bot";
    wantedBy = [ "multi-user.target" ];
    requires = [ "tuwunel.service" ];
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "tuwunel.service"
    ];
    unitConfig.ConditionPathExists = config.sops.templates."matrix-invite-bot.env".path;

    serviceConfig = {
      User = "matrix-invite-bot";
      Group = "matrix-invite-bot";
      StateDirectory = "matrix-invite-bot";
      StateDirectoryMode = "0700";
      EnvironmentFile = config.sops.templates."matrix-invite-bot.env".path;
      ExecStart = lib.getExe inviteBot;
      Restart = "on-failure";
      RestartSec = "30s";
      UMask = "0077";

      IPAddressDeny = "any";
      IPAddressAllow = [
        "localhost"
        # Guest tuwunel: the bot toggles registration via its Admin API.
        "10.77.3.17"
      ];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      RestrictNamespaces = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" ];
    };
  };

  system.stateVersion = "26.05";
}
