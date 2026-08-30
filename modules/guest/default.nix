{ configurationName, pkgs, ... }:

{
  boot.isContainer = true;
  # Incus guests are managed through incus exec and have no usable /dev/console.
  systemd.services.console-getty.enable = false;
  # Use only the init update from lxc-container.nix; the rest is for building LXC images.
  system.build.installBootLoader = pkgs.writeShellScript "install-lxc-init" ''
    ${pkgs.coreutils}/bin/ln -fs "$1/init" /sbin/init
  '';

  system.autoUpgrade = {
    enable = false;
    flake = "github:s3-odara/infra#${configurationName}";
    upgrade = false;
    allowReboot = false;
    randomizedDelaySec = "1h";
    fixedRandomDelay = true;
    persistent = false;
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  nix.gc = {
    automatic = true;
    dates = "*-*-* 06:00:00 Asia/Tokyo";
    randomizedDelaySec = "30m";
    options = "--delete-older-than 7d";
  };

  # Keep each guest's daily GC at a stable offset within the delay window.
  systemd.timers.nix-gc.timerConfig.FixedRandomDelay = true;

  services.journald.extraConfig = ''
    SystemMaxUse=200M
    MaxRetentionSec=14day
  '';
}
