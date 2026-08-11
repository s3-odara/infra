{ lib, ... }:

{
  disko.devices.disk.main = {
    type = "disk";

    # Vultr Cloud Compute commonly exposes the system disk as /dev/vda.
    # Verify with `lsblk` on the temporary OS before installing.
    device = lib.mkDefault "/dev/vda";

    content = {
      type = "gpt";

      partitions = {
        ESP = {
          size = "512M";
          type = "EF00";

          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        swap = {
          size = "4G";

          content = {
            type = "swap";
            randomEncryption = true;
          };
        };
        root = {
          size = "100%";

          content = {
            type = "btrfs";
            extraArgs = [ "-f" ];

            subvolumes = {
              "@" = {
                mountpoint = "/";
                mountOptions = [
                  "compress=zstd"
                  "noatime"
                ];
              };

              "@nix" = {
                mountpoint = "/nix";
                mountOptions = [
                  "compress=zstd"
                  "noatime"
                ];
              };

              "@incus" = {
                mountpoint = "/var/lib/incus-storage";
                mountOptions = [
                  "compress=zstd"
                  "noatime"
                ];
              };
            };
          };
        };
      };
    };
  };
}
