{
  config,
  configurationName,
  pkgs,
  ...
}:

let
  oneshotHardening = import ../../modules/guest/oneshot-hardening.nix;
  privateAddress = "10.77.3.18";
  collectionsDirectory = "/var/lib/radicale/collections";
  r2Endpoint = "https://6ecd930c8cd4dc63f87c9398762626e8.r2.cloudflarestorage.com";

  # Keep the shared lock for the complete direct transfer. Open read-only so a
  # backup never creates a root-owned lock or initializes missing service state.
  storageReadLock = ''
    exec 9<${collectionsDirectory}/.Radicale.lock
    ${pkgs.util-linux}/bin/flock --shared --timeout 60 9
  '';

  resticWithStorageLock = pkgs.writeShellScriptBin "restic" ''
    set -euo pipefail
    # The generated service invokes the subcommand first. Repository setup,
    # pruning and recovery do not read live storage and must remain unlocked.
    if [[ "''${1:-}" == backup ]]; then
      ${storageReadLock}
    fi
    exec ${pkgs.restic}/bin/restic "$@"
  '';

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
      --data-binary "Radicale backup failed" \
      "https://ntfy.sh/$topic"
  '';
in
{
  networking.hostName = configurationName;
  networking.useDHCP = true;
  networking.firewall.enable = false;

  networking.nftables = {
    enable = true;
    flushRuleset = false;
    tables.radicale-egress = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy accept;
          meta skuid "radicale" ct direction reply counter accept
          meta skuid "radicale" counter reject with icmpx type admin-prohibited
        }
      '';
    };
    preCheckRuleset = ''
      substituteInPlace ruleset.conf \
        --replace-fail 'meta skuid "radicale"' 'meta skuid 65534'
    '';
  };

  services.radicale = {
    enable = true;
    settings = {
      server = {
        hosts = [ "${privateAddress}:5232" ];
        max_connections = 20;
        max_content_length = 100000000;
      };
      auth = {
        type = "htpasswd";
        htpasswd_filename = "/run/credentials/radicale.service/htpasswd";
        htpasswd_encryption = "bcrypt";
      };
      rights.type = "owner_only";
      sharing.type = "none";
      storage.filesystem_folder = collectionsDirectory;
    };
  };

  systemd.services.radicale = {
    bindsTo = [ "nftables.service" ];
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "nftables.service"
      "sops-nix.service"
    ];
    # Create the storage lock as radicale, even before the first DAV request.
    preStart = ''
      ${pkgs.coreutils}/bin/touch ${collectionsDirectory}/.Radicale.lock
    '';
    serviceConfig = {
      LoadCredential = [
        "htpasswd:${config.sops.secrets.radicale_htpasswd.path}"
      ];
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  sops = {
    secrets = {
      radicale_htpasswd = {
        mode = "0400";
        restartUnits = [ "radicale.service" ];
      };
      ntfy_topic = { };
      r2_access_key_id = { };
      r2_secret_access_key = { };
      restic_repository_password = { };
    };
    templates."restic-r2.env" = {
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

  services.restic.backups.radicale = {
    repository = "s3:${r2Endpoint}/radicale/restic";
    package = resticWithStorageLock;
    paths = [ collectionsDirectory ];
    exclude = [
      "${collectionsDirectory}/.Radicale.lock"
      "**/.Radicale.cache"
      "**/.Radicale.tmp-*"
    ];
    environmentFile = config.sops.templates."restic-r2.env".path;
    passwordFile = config.sops.secrets.restic_repository_password.path;
    initialize = true;
    pruneOpts = [
      "--keep-daily 14"
      "--keep-weekly 8"
    ];
    timerConfig = {
      OnCalendar = "*-*-* 03:50:00 Asia/Tokyo";
      Persistent = true;
      RandomizedDelaySec = "3m";
      FixedRandomDelay = true;
      AccuracySec = "1s";
    };
  };

  systemd.services."restic-backups-radicale" = {
    unitConfig.OnFailure = "backup-failure-notify@%n.service";
    serviceConfig = oneshotHardening.backup;
  };

  systemd.services.radicale-monthly-backup = {
    description = "Create an encrypted monthly Radicale backup";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    unitConfig.OnFailure = "backup-failure-notify@%n.service";
    serviceConfig = oneshotHardening.backup // {
      Type = "oneshot";
      EnvironmentFile = config.sops.templates."restic-r2.env".path;
    };
    script = ''
      set -euo pipefail
      month="$(TZ=Asia/Tokyo ${pkgs.coreutils}/bin/date +%Y-%m)"
      timestamp="$(${pkgs.coreutils}/bin/date --utc +%Y%m%dT%H%M%SZ)"
      recipient="$(${pkgs.age}/bin/age-keygen -y ${config.sops.age.keyFile})"
      export RCLONE_CONFIG_R2_TYPE=s3
      export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
      export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
      export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
      export RCLONE_CONFIG_R2_ENDPOINT=${r2Endpoint}
      export RCLONE_CONFIG_R2_REGION=auto
      export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

      ${storageReadLock}
      ${pkgs.gnutar}/bin/tar \
        --create --file=- --directory=${collectionsDirectory} \
        --numeric-owner --acls --xattrs --sparse \
        --exclude='./.Radicale.lock' \
        --exclude='.Radicale.cache' \
        --exclude='.Radicale.tmp-*' . \
        | ${pkgs.zstd}/bin/zstd --quiet --threads=1 --stdout \
        | ${pkgs.age}/bin/age --encrypt --recipient "$recipient" \
        | ${pkgs.rclone}/bin/rclone --config /dev/null rcat \
          "r2:radicale/archive/$month/$timestamp.tar.zst.age"
    '';
  };

  systemd.timers.radicale-monthly-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-01 02:50:00 Asia/Tokyo";
      Persistent = true;
      RandomizedDelaySec = "3m";
      FixedRandomDelay = true;
      AccuracySec = "1s";
    };
  };

  systemd.services."backup-failure-notify@".serviceConfig = oneshotHardening.notification // {
    Type = "oneshot";
    LoadCredential = [ "ntfy-topic:${config.sops.secrets.ntfy_topic.path}" ];
    ExecStart = backupFailureNotifier;
  };

  system.stateVersion = "26.05";
}
