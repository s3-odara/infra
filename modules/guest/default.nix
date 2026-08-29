{ configurationName, pkgs, ... }:

{
  boot.isContainer = true;
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
    dates = "daily";
    options = "--delete-older-than 7d";
  };

  services.journald.extraConfig = ''
    SystemMaxUse=200M
    MaxRetentionSec=14day
  '';
}
