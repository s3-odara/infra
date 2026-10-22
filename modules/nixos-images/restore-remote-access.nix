# Compatibility copy of nix-community/nixos-images/nix/restore-remote-access.nix.
# boot.initrd.systemd.enable was removed after scripted initrd was dropped.
{
  boot.initrd.systemd.services.restore-state-from-initrd = {
    unitConfig = {
      DefaultDependencies = false;
      RequiresMountsFor = "/sysroot /dev";
    };
    wantedBy = [ "initrd.target" ];
    requiredBy = [ "rw-etc.service" ];
    before = [ "rw-etc.service" ];
    serviceConfig.Type = "oneshot";
    # Restore SSH host and user keys if they are available.
    # This avoids warnings of unknown SSH keys.
    script = ''
      mkdir -m 700 -p /sysroot/root/.ssh
      mkdir -m 755 -p /sysroot/etc/ssh
      mkdir -m 755 -p /sysroot/root/network
      if [[ -f ssh/authorized_keys ]]; then
        install -m 400 ssh/authorized_keys /sysroot/root/.ssh
      fi
      install -m 400 ssh/ssh_host_* /sysroot/etc/ssh
      cp *.json /sysroot/root/network/
      if [[ -f machine-id ]]; then
        cp machine-id /sysroot/etc/machine-id
      fi
    '';
  };
}
