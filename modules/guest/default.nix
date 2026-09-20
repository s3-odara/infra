{ configurationName, pkgs, ... }:

let
  journalUpload = pkgs.writeShellScript "guest-journal-upload" ''
    route=$(${pkgs.iproute2}/bin/ip -4 route show default)
    set -- $route
    gateway=
    while [ "$#" -gt 1 ]; do
      if [ "$1" = via ]; then
        gateway=$2
        break
      fi
      shift
    done
    if [ -z "$gateway" ]; then
      echo "guest-journal-upload: default IPv4 gateway not found" >&2
      exit 1
    fi
    exec ${pkgs.systemd}/lib/systemd/systemd-journal-upload \
      --save-state \
      --url="http://$gateway:19532"
  '';
in
{
  imports = [ ../cachix.nix ];

  # Nix may need Git to fetch git-based sources while evaluating a remote flake.
  environment.systemPackages = [ pkgs.gitMinimal ];

  boot.isContainer = true;
  # Incus guests are managed through incus exec and have no usable /dev/console.
  systemd.services.console-getty.enable = false;
  # Use only the init update from lxc-container.nix; the rest is for building LXC images.
  system.build.installBootLoader = pkgs.writeShellScript "install-lxc-init" ''
    ${pkgs.coreutils}/bin/ln -fs "$1/init" /sbin/init
  '';

  system.autoUpgrade = {
    enable = true;
    dates = "*-*-* 04:15:00 Asia/Tokyo";
    flake = "github:s3-odara/infra#${configurationName}";
    upgrade = false;
    allowReboot = false;
    randomizedDelaySec = "15m";
    fixedRandomDelay = true;
    persistent = false;
  };
  systemd.timers.nixos-upgrade.timerConfig.AccuracySec = "1s";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  nix.gc = {
    automatic = true;
    dates = "*-*-* 04:45:00 Asia/Tokyo";
    randomizedDelaySec = "15m";
    persistent = false;
    options = "--delete-older-than 3d";
  };

  # Keep each guest's GC at a stable offset within the delay window.
  systemd.timers.nix-gc.timerConfig = {
    FixedRandomDelay = true;
    AccuracySec = "1s";
  };

  # Container root filesystems are Btrfs subvolumes trimmed by the host.
  services.fstrim.enable = false;
  systemd.timers.logrotate.timerConfig = {
    Persistent = false;
    RandomizedDelaySec = "1h";
    FixedRandomDelay = true;
    AccuracySec = "1s";
  };

  services.journald = {
    settings.Journal = {
      SystemMaxUse = "200M";
      MaxFileSec = "1day";
      MaxRetentionSec = "14day";
    };
    upload = {
      enable = true;
      # The command-line URL below is resolved from the runtime default route.
      settings.Upload.URL = "http://127.0.0.1:19532";
    };
  };

  systemd.services.systemd-journal-upload = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = [
        ""
        journalUpload
      ];
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      RestrictRealtime = true;
      RestrictNamespaces = true;
      LockPersonality = true;
      UMask = "0077";
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_NETLINK"
      ];
    };
  };
}
