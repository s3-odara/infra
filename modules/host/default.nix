{
  configurationName,
  lib,
  pkgs,
  ...
}:

let
  secretSource = ../../secrets/hosts/${configurationName}/secrets.sops.yaml;
  hasSecrets = builtins.pathExists secretSource;
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
      curl
      gnugrep
      incus
      inetutils
      sops
      systemd
    ];
    text = builtins.readFile ./health-monitor.sh;
  };
in
{
  services.journald.extraConfig = ''
    SystemMaxUse=200M
    MaxRetentionSec=14day
  '';

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

  systemd.services.host-storage-monitor = lib.mkIf hasSecrets {
    description = "Check host and Incus container storage usage";
    after = [ "incus.service" ];
    requires = [ "incus.service" ];
    environment.STORAGE_MONITOR_SECRET_FILE = secretFile;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe storageMonitor;
    };
  };

  systemd.timers.host-storage-monitor = lib.mkIf hasSecrets {
    description = "Daily host and Incus container storage usage check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  systemd.services.host-health-monitor = lib.mkIf hasSecrets {
    description = "Check Incus container states and kernel health events";
    after = [ "incus.service" ];
    requires = [ "incus.service" ];
    environment.HOST_MONITOR_SECRET_FILE = secretFile;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe healthMonitor;
      SupplementaryGroups = [ "systemd-journal" ];
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
