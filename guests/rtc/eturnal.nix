{
  config,
  lib,
  pkgs,
  ...
}:

let
  eturnal = pkgs.callPackage ../../packages/eturnal/package.nix { };
  settingsFormat = pkgs.formats.yaml { };
  privateAddress = "10.77.3.15";
  publicAddress = "15.235.184.173";
  turnHost = "turn.odarah.org";
  credentialsDirectory = "/run/credentials/eturnal.service";

  configFile = settingsFormat.generate "eturnal.yml" {
    eturnal = {
      listen = [
        {
          ip = privateAddress;
          port = 3478;
          transport = "udp";
        }
        {
          ip = privateAddress;
          port = 3478;
          transport = "tcp";
        }
        {
          ip = privateAddress;
          port = 5349;
          transport = "tls";
        }
      ];
      tls_crt_file = "${credentialsDirectory}/tls-cert";
      tls_key_file = "${credentialsDirectory}/tls-key";
      tls_options = [
        "no_tlsv1"
        "no_tlsv1_1"
        "cipher_server_preference"
      ];
      relay_ipv4_addr = publicAddress;
      relay_ipv6_addr = "none";
      relay_min_port = 49160;
      relay_max_port = 49200;
      blacklist_peers = [ "recommended" ];
      strict_expiry = false;
      log_dir = "stdout";
    };
  };
in
{
  environment.etc."eturnal/eturnal.yml".source = configFile;

  users.groups.eturnal = { };
  users.users.eturnal = {
    isSystemUser = true;
    group = "eturnal";
    description = "eturnal STUN/TURN server";
    home = "/var/lib/eturnal";
  };

  systemd.services.eturnal = {
    description = "eturnal STUN/TURN server";
    documentation = [ "https://eturnal.net/doc/" ];
    wantedBy = [ "multi-user.target" ];
    wants = [
      "acme-${turnHost}.service"
      "network-online.target"
    ];
    after = [
      "acme-${turnHost}.service"
      "network-online.target"
    ];

    environment = {
      ETURNAL_ETC_DIR = "/etc/eturnal";
      ERL_DIST_PORT = "3470";
    };

    script = ''
      export ETURNAL_SECRET="$(<"$CREDENTIALS_DIRECTORY/turn-secret")"
      exec ${lib.getExe' eturnal "eturnalctl"} foreground
    '';

    serviceConfig = {
      Type = "notify";
      User = "eturnal";
      Group = "eturnal";
      Environment = [ "HOME=/var/lib/eturnal" ];
      LoadCredential = [
        "turn-secret:${config.sops.secrets.turn_external_secret.path}"
        "tls-cert:/var/lib/acme/${turnHost}/fullchain.pem"
        "tls-key:/var/lib/acme/${turnHost}/key.pem"
      ];

      ExecStop = "${lib.getExe' eturnal "eturnalctl"} stop";
      Restart = "on-failure";
      RestartSec = "3s";
      WatchdogSec = "30s";
      LimitNOFILE = 50000;
      RuntimeDirectory = "eturnal";
      RuntimeDirectoryMode = "0750";
      StateDirectory = "eturnal";
      StateDirectoryMode = "0750";
      UMask = "0077";

      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      PrivateUsers = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectProc = "invisible";
      ProtectSystem = "strict";
      ProcSubset = "pid";
      RemoveIPC = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
        "AF_NETLINK"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
        "@resources"
      ];
      CapabilityBoundingSet = [ "" ];
    };
  };
}
