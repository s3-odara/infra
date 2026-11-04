let
  base = {
    CapabilityBoundingSet = "";
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateIPC = true;
    PrivateTmp = true;
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectProc = "invisible";
    ProtectSystem = "strict";
    RemoveIPC = true;
    RestrictAddressFamilies = [
      "AF_UNIX"
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
    ];
    TimeoutStartSec = "1m";
    UMask = "0077";
  };
in
{
  inherit base;

  backup = base // {
    # Read service-owned state and connect to Knot's control socket without
    # retaining mount, ptrace, network-administration, or other capabilities.
    CapabilityBoundingSet = [
      "CAP_DAC_READ_SEARCH"
      "CAP_DAC_OVERRIDE"
    ];
    TimeoutStartSec = "10m";
  };

  notification = base // {
    DynamicUser = true;
    MemoryMax = "64M";
    TasksMax = 32;
    TimeoutStartSec = "30s";
  };
}
