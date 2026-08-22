{
  config,
  configurationName,
  lib,
  pkgs,
  ...
}:

let
  inviteBot = pkgs.rustPlatform.buildRustPackage {
    pname = "matrix-invite-bot";
    version = "0.1.0";
    src = ./invite-bot;
    cargoHash = "sha256-xK0j+t2CxEU730ujUcYiOiRPmXPDj9zr2158fpwYA+I=";
    meta.mainProgram = "matrix-invite-bot";
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.sqlite ];
  };
  registrationToken = "/var/lib/tuwunel/registration-token";
  backupDirectory = "/var/lib/tuwunel-backups";
in
{
  boot.isContainer = true;
  networking.hostName = configurationName;
  networking.useDHCP = true;
  networking.firewall.enable = false;

  environment.systemPackages = [
    inviteBot
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
      max_request_size = 24 * 1024 * 1024;
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
      database_backup_path = backupDirectory;
      database_backups_to_keep = 2;
      admin_signal_execute = [ "server backup-database" ];
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
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl kill --kill-whom=main --signal=SIGUSR2 tuwunel.service";
    };
  };

  systemd.timers.tuwunel-online-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 00:00:00";
      RandomizedDelaySec = "1h";
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
      r2_access_key_id = { };
      r2_secret_access_key = { };
      restic_repository_password = { };
      matrix_invite_bot_device_id = { };
      matrix_invite_bot_access_token = { };
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
        '';
        owner = "root";
        group = "root";
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
      "--keep-monthly 6"
    ];
    backupPrepareCommand = ''
      set -eu
      state=/run/restic-backups-tuwunel/invite-bot-was-active

      if ${pkgs.systemd}/bin/systemctl is-active --quiet matrix-invite-bot.service; then
        ${pkgs.coreutils}/bin/touch "$state"
        ${pkgs.systemd}/bin/systemctl stop matrix-invite-bot.service
      fi
    '';
    backupCleanupCommand = ''
      status=0
      state=/run/restic-backups-tuwunel/invite-bot-was-active

      if test -e "$state"; then
        ${pkgs.systemd}/bin/systemctl start matrix-invite-bot.service || status=$?
      fi
      ${pkgs.coreutils}/bin/rm -f "$state" || test "$status" -ne 0 || status=$?
      exit "$status"
    '';
    timerConfig = {
      OnCalendar = "*-*-* 12:00:00";
      RandomizedDelaySec = "1h";
      FixedRandomDelay = true;
      Persistent = false;
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
      IPAddressAllow = "localhost";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      RestrictNamespaces = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" ];
    };
  };

  system.stateVersion = "26.05";
}
