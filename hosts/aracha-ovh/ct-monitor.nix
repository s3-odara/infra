{ lib, pkgs, ... }:

let
  secretSource = ../../secrets/hosts/aracha-ovh/secrets.sops.yaml;
  secretFile = builtins.path {
    path = secretSource;
    name = "aracha-ovh-secrets.sops.yaml";
  };
  policyFile = pkgs.writeText "ct-monitor-policy.json" (
    builtins.toJSON {
      certificates = [
        {
          name = "nginx";
          pubkeySha256 = "6369a2028d62f3a014e3e0a98cd32604b1451c988275fcc451b8a77b335caa5b";
          dnsNames = [
            "cinny.matrix.odarah.org"
            "element.matrix.odarah.org"
            "matrix.odarah.org"
            "odarah.org"
            "push.matrix.odarah.org"
            "rtc.matrix.odarah.org"
            "sable.matrix.odarah.org"
          ];
        }
        {
          name = "prosody";
          pubkeySha256 = "63b7ac93e4d7f23b04359d2892e3ead081d5fcf632bf266d099b3c351bca4b6e";
          dnsNames = [
            "conference.xmpp.odarah.org"
            "share.xmpp.odarah.org"
            "xmpp.odarah.org"
          ];
        }
        {
          name = "rtc";
          pubkeySha256 = "fdb58517af42dcbf5ac5ae62082c7797bee5845bfd8ba9fa128a6f2d4880f041";
          dnsNames = [ "turn.odarah.org" ];
        }
      ];
    }
  );
  ctMonitor = pkgs.writeShellApplication {
    name = "ct-monitor";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
      sops
    ];
    text = builtins.readFile ../../modules/host/ct-monitor.sh;
  };
  serviceHardening = {
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
in
{
  systemd.services.ct-monitor = {
    description = "Monitor Certificate Transparency issuances for odarah.org";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    environment = {
      CT_MONITOR_CURSOR_FILE = "/var/lib/ct-monitor/cursor";
      CT_MONITOR_INITIAL_CURSOR = "16955548675";
      CT_MONITOR_POLICY_FILE = policyFile;
      CT_MONITOR_SECRET_FILE = secretFile;
    };
    serviceConfig = serviceHardening // {
      Type = "oneshot";
      StateDirectory = "ct-monitor";
      StateDirectoryMode = "0700";
      TimeoutStartSec = "10m";
      ExecStart = lib.getExe ctMonitor;
    };
  };

  systemd.timers.ct-monitor = {
    description = "15-minute Certificate Transparency issuance check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/15";
      Persistent = true;
      RandomizedDelaySec = "2m";
      FixedRandomDelay = true;
    };
  };
}
