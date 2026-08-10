resource "incus_storage_pool" "default" {
  name   = "default"
  driver = "btrfs"
  config = {
    source = "/var/lib/incus-storage"
  }

  description = "Storage for restricted service containers"
}
