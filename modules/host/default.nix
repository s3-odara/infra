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
      jq
      sops
    ];
    text = builtins.readFile ./storage-monitor.sh;
  };
in
{
  services.journald.extraConfig = ''
    SystemMaxUse=200M
    MaxRetentionSec=14day
  '';

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
}
