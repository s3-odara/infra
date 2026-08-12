resource "incus_project" "user" {
  name        = "user-1000"
  description = "Restricted project for UID 1000"

  config = {
    # Project-local resources

    "features.images"          = "true"
    "features.networks"        = "false"
    "features.profiles"        = "true"
    "features.storage.volumes" = "true"
    "features.storage.buckets" = "false"

    # Restricted project

    "restricted"                      = "true"
    "restricted.containers.privilege" = "isolated"
    # NixOS containerではsecurity.nesting=trueを使う。
    "restricted.containers.nesting" = "allow"

    # managed resourceだけ利用可能。
    "restricted.devices.disk" = "managed"
    "restricted.devices.nic"  = "managed"

    # この2つ以外のhost resourcesにはアクセス不可。
    "restricted.networks.access"      = incus_network.incusbr0.name
    "restricted.storage-pools.access" = incus_storage_pool.default.name
  }
}
