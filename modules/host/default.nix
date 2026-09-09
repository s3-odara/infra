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
  storageMonitor = pkgs.writeShellApplication {
    name = "host-storage-monitor";
    runtimeInputs = with pkgs; [
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
  services.journald = {
    settings.Journal = {
      SystemMaxUse = "200M";
      MaxFileSec = "1day";
      MaxRetentionSec = "14day";
    };
    remote = {
      enable = true;
      output = "/var/log/journal/remote";
      settings.Remote = {
        MaxUse = "200M";
        MaxFileSize = "10M";
        SplitMode = "none";
      };
    };
  };

  systemd.sockets.systemd-journal-remote = {
    after = [ "incus.service" ];
    requires = [ "incus.service" ];
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

  system.autoUpgrade = {
    enable = false;
    flake = "github:s3-odara/infra#${configurationName}";
    upgrade = false;
    allowReboot = true;
  };

  # The host kernels use CONFIG_MODULES=n.
  boot.modprobeConfig.enable = false;

  systemd.services.guest-journal-vacuum = {
    description = "Expire archived remote guest journals";
    serviceConfig = monitorHardening // {
      Type = "oneshot";
      ExecStart = lib.getExe journalVacuum;
      ReadWritePaths = [ "/var/log/journal/remote" ];
    };
  };
  systemd.timers.guest-journal-vacuum = {
    description = "Daily remote guest journal retention";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
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
      OnCalendar = "*-*-* 06:30:00 Asia/Tokyo";
      Persistent = true;
      RandomizedDelaySec = "30m";
      FixedRandomDelay = true;
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
      Persistent = true;
    };
  };
}
