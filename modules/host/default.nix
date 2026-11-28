{
  configurationName,
  lib,
  pkgs,
  ...
}:

let
  secretSource = ../../secrets/hosts/${configurationName}/secrets.sops.yaml;
  hasSecrets = builtins.pathExists secretSource;
  monitorEnvironment = {
    # Avoid the inaccessible root-owned client config with ProtectHome enabled.
    INCUS_CONF = "/run/host-monitor-incus";
  };
  monitorHardening = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    RestrictRealtime = true;
    RestrictNamespaces = true;
    LockPersonality = true;
    RemoveIPC = true;
    MemoryDenyWriteExecute = true;
    CapabilityBoundingSet = "";
    SystemCallArchitectures = "native";
    UMask = "0077";
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
    ];
  };
  secretFile = builtins.path {
    path = secretSource;
    name = "${configurationName}-secrets.sops.yaml";
  };
  btrfsRootUsage = pkgs.writeShellApplication {
    name = "btrfs-root-usage";
    runtimeInputs = with pkgs; [ gawk ];
    text = ''
      read_uint() {
        local value

        value=$(<"$1")
        [[ $value =~ ^[0-9]+$ ]] || {
          echo "Invalid numeric value in $1: $value" >&2
          exit 1
        }
        printf '%s\n' "$value"
      }

      root_dev=$(awk '$5 == "/" {
        for (i = 7; i <= NF; i++) {
          if ($i == "-" && $(i + 1) == "btrfs") {
            sub(/^.*\//, "", $(i + 2))
            print $(i + 2)
            exit
          }
        }
      }' /proc/self/mountinfo)
      [[ -n $root_dev ]] || {
        echo "Failed to resolve Btrfs root device from /proc/self/mountinfo" >&2
        exit 1
      }

      shopt -s nullglob
      btrfs_matches=(/sys/fs/btrfs/*/devices/"$root_dev")
      shopt -u nullglob
      (( ''${#btrfs_matches[@]} == 1 )) || {
        echo "Failed to resolve Btrfs sysfs directory for / (device: $root_dev)" >&2
        exit 1
      }
      btrfs_dir=''${btrfs_matches[0]%/devices/"$root_dev"}

      device_size=0
      for size_file in "$btrfs_dir"/devices/*/size; do
        sectors=$(read_uint "$size_file")
        ((device_size += sectors * 512))
      done
      ((device_size > 0)) || {
        echo "Failed to read Btrfs device size from $btrfs_dir" >&2
        exit 1
      }

      data_disk=$(read_uint "$btrfs_dir/allocation/data/disk_total")
      metadata_disk=$(read_uint "$btrfs_dir/allocation/metadata/disk_total")
      system_disk=$(read_uint "$btrfs_dir/allocation/system/disk_total")
      allocated=$((data_disk + metadata_disk + system_disk))
      if ((allocated > device_size)); then
        unallocated=0
      else
        unallocated=$((device_size - allocated))
      fi

      metadata_used=$(read_uint "$btrfs_dir/allocation/metadata/bytes_used")
      metadata_size=$(read_uint "$btrfs_dir/allocation/metadata/total_bytes")
      ((metadata_size > 0)) || {
        echo "Invalid Btrfs metadata total_bytes in $btrfs_dir" >&2
        exit 1
      }

      printf '%s %s %s %s\n' "$unallocated" "$device_size" "$metadata_used" "$metadata_size"
    '';
  };
  storageMonitor = pkgs.writeShellApplication {
    name = "host-storage-monitor";
    runtimeInputs = with pkgs; [
      btrfsRootUsage
      coreutils
      curl
      gawk
      incus
      inetutils
      jq
      sops
    ];
    text = builtins.readFile ./storage-monitor.sh;
  };
  btrfsBalance = pkgs.writeShellApplication {
    name = "btrfs-balance";
    runtimeInputs = with pkgs; [
      btrfs-progs
      btrfsRootUsage
    ];
    text = ''
      usage=$(btrfs-root-usage)
      read -r unallocated device_size _ _ <<<"$usage"

      min_unallocated=$((4 * 1024 * 1024 * 1024))
      if ((unallocated >= min_unallocated && unallocated * 10 >= device_size)); then
        exit 0
      fi

      btrfs balance start -dusage=50 -dlimit=5 /var/lib/btrfs-balance
    '';
  };
  healthMonitor = pkgs.writeShellApplication {
    name = "host-health-monitor";
    runtimeInputs = with pkgs; [
      chrony
      curl
      gnugrep
      incus
      inetutils
      sops
      systemd
    ];
    text = builtins.readFile ./health-monitor.sh;
  };
  journalVacuum = pkgs.writeShellApplication {
    name = "guest-journal-vacuum";
    runtimeInputs = with pkgs; [ systemd ];
    text = ''
      journalctl --directory=/var/log/journal/remote \
        --vacuum-time=14d \
        --vacuum-size=200M
    '';
  };
in
{
  imports = [ ../cachix.nix ];

  # CONFIG_MODULES=n leaves an empty /lib/modules directory in buildEnv. Avoid
  # passing that directory's `.` entry to depmod in aggregateModules.
  nixpkgs.overlays = [
    (final: prev: {
      aggregateModules =
        modules:
        (prev.aggregateModules modules).overrideAttrs (old: {
          postBuild = ''
            shopt -s nullglob
            modulePaths=("$out/lib/modules/"*)
            shopt -u nullglob
            if [ "''${#modulePaths[@]}" -eq 0 ]; then
              echo "No modules found."
              exit 0
            fi
          ''
          + old.postBuild;
        });
    })
  ];

  services.journald = {
    settings.Journal = {
      SystemMaxUse = "200M";
      MaxFileSec = "1day";
      MaxRetentionSec = "14day";
    };
    remote = {
      enable = true;
      output = "/var/log/journal/remote/remote.journal";
      settings.Remote = {
        MaxUse = "200M";
        MaxFileSize = "10M";
        SplitMode = "none";
      };
    };
  };

  systemd.sockets.systemd-journal-remote = {
    # Incus creates the bridge asynchronously; wait for the device before
    # binding the socket and stop it if the bridge disappears.
    # Incus starts after basic.target, so this late socket must not inherit
    # Before=sockets.target. Keep the shutdown dependencies explicitly.
    unitConfig.DefaultDependencies = false;
    before = [ "shutdown.target" ];
    conflicts = [ "shutdown.target" ];
    after = [
      "incus.service"
      "sys-subsystem-net-devices-incusbr0.device"
    ];
    requires = [ "incus.service" ];
    bindsTo = [ "sys-subsystem-net-devices-incusbr0.device" ];
    partOf = [ "incus.service" ];
    wantedBy = [ "sys-subsystem-net-devices-incusbr0.device" ];
    socketConfig.BindToDevice = "incusbr0";
  };
  networking.firewall.interfaces.incusbr0.allowedTCPPorts = [ 19532 ];

  services.chrony = {
    enable = true;
    servers = [ "time.cloudflare.com" ];
    enableNTS = true;

    makestep = {
      enable = true;
      threshold = 1.0;
      limit = 3;
    };

    extraConfig = ''
      # Operate only as an authenticated NTS client.
      port 0
      cmdport 0
      authselectmode require

      maxupdateskew 100
      maxdrift 50
      maxchange 10 0 5
      logchange 0.5
    '';
  };

  # chronyc creates a reply socket under /run/chrony. Let the capability-free
  # health monitor use it through membership in the chrony group.
  systemd.services.chronyd.serviceConfig.UMask = lib.mkForce "0007";
  systemd.tmpfiles.rules = [ "d /run/chrony 0770 chrony chrony - -" ];

  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      LoginGraceTime = 60;
      MaxStartups = "10:30:60";
      PerSourceMaxStartups = 3;
      PerSourcePenalties = "min:30s authfail:10s invaliduser:10s grace-exceeded:30s max:10m";
      AllowUsers = [ "me" ];
      DisableForwarding = true;
      PermitUserEnvironment = false;
      LogLevel = "VERBOSE";
    };
  };

  networking.firewall.interfaces.uplink0.allowedTCPPorts = [ 22 ];

  # Current workloads do not require IPv4 options. Drop them on all interfaces
  # at the host's prerouting hook before conntrack, including forwarded traffic.
  networking.nftables.tables."ipv4-options-guard" = {
    family = "inet";
    content = ''
      chain pre {
        type filter hook prerouting priority -310; policy accept;
        ip hdrlength gt 5 counter drop
      }
    '';
  };

  system.autoUpgrade = {
    enable = true;
    dates = "*-*-* 04:20:00 Asia/Tokyo";
    flake = "github:s3-odara/infra#${configurationName}";
    upgrade = false;
    allowReboot = true;
    randomizedDelaySec = "3m";
    fixedRandomDelay = true;
    persistent = false;
  };
  systemd.timers.nixos-upgrade.timerConfig.AccuracySec = "1s";

  nix.gc = {
    automatic = true;
    dates = "*-*-* 04:00:00 Asia/Tokyo";
    randomizedDelaySec = "15m";
    persistent = false;
    options = "--delete-older-than 3d";
  };
  systemd.timers.nix-gc.timerConfig = {
    FixedRandomDelay = true;
    AccuracySec = "1s";
  };

  systemd.services.btrfs-balance = {
    description = "Reclaim partially used Btrfs data chunks on /";
    serviceConfig = monitorHardening // {
      Type = "oneshot";
      # Keep ProtectSystem=strict by targeting a writable directory on the same
      # Btrfs filesystem; BTRFS_IOC_BALANCE_V2 still balances the whole filesystem.
      StateDirectory = "btrfs-balance";
      StateDirectoryMode = "0700";
      CapabilityBoundingSet = [ "CAP_SYS_ADMIN" ];
      RestrictAddressFamilies = "none";
      Nice = 19;
      IOSchedulingClass = "idle";
      ExecStart = lib.getExe btrfsBalance;
    };
  };
  systemd.timers.btrfs-balance = {
    description = "Daily lightweight Btrfs data chunk balance";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 05:30:00 Asia/Tokyo";
      Persistent = false;
      RandomizedDelaySec = "15m";
      FixedRandomDelay = true;
      AccuracySec = "1s";
    };
  };

  services.fstrim.enable = false;
  systemd.timers.logrotate.timerConfig = {
    Persistent = false;
    RandomizedDelaySec = "1h";
    FixedRandomDelay = true;
    AccuracySec = "1s";
  };

  # The host kernels use CONFIG_MODULES=n.
  boot.modprobeConfig.enable = false;

  systemd.services.guest-journal-vacuum = {
    description = "Expire archived remote guest journals";
    serviceConfig = monitorHardening // {
      Type = "oneshot";
      User = "systemd-journal-remote";
      Group = "systemd-journal-remote";
      ExecStart = lib.getExe journalVacuum;
      ReadWritePaths = [ "/var/log/journal/remote" ];
    };
  };
  systemd.timers.guest-journal-vacuum = {
    description = "Daily remote guest journal retention";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 05:05:00 Asia/Tokyo";
      Persistent = false;
      RandomizedDelaySec = "3m";
      FixedRandomDelay = true;
      AccuracySec = "1s";
    };
  };

  systemd.services.host-storage-monitor = lib.mkIf hasSecrets {
    description = "Check host and Incus container storage usage";
    after = [ "incus.service" ];
    requires = [ "incus.service" ];
    environment = monitorEnvironment // {
      STORAGE_MONITOR_SECRET_FILE = secretFile;
    };
    serviceConfig = monitorHardening // {
      Type = "oneshot";
      ExecStart = lib.getExe storageMonitor;
    };
  };

  systemd.timers.host-storage-monitor = lib.mkIf hasSecrets {
    description = "Daily host and Incus container storage usage check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 06:00:00 Asia/Tokyo";
      Persistent = true;
      RandomizedDelaySec = "1h";
      FixedRandomDelay = true;
      AccuracySec = "1s";
    };
  };

  systemd.services.host-health-monitor = lib.mkIf hasSecrets {
    description = "Check Incus container states and kernel health events";
    after = [ "incus.service" ];
    requires = [ "incus.service" ];
    environment = monitorEnvironment // {
      HOST_MONITOR_SECRET_FILE = secretFile;
    };
    serviceConfig = monitorHardening // {
      Type = "oneshot";
      ExecStart = lib.getExe healthMonitor;
      SupplementaryGroups = [
        "chrony"
        "systemd-journal"
      ];
    };
  };

  systemd.timers.host-health-monitor = lib.mkIf hasSecrets {
    description = "15-minute host health check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/15";
      Persistent = false;
      RandomizedDelaySec = "15m";
      FixedRandomDelay = true;
      AccuracySec = "1s";
    };
  };
}
