resource "incus_profile" "default" {
  name        = "default"
  project     = incus_project.user.name
  description = "Default restricted-user profile"

  device {
    name = "root"
    type = "disk"

    properties = {
      pool = incus_storage_pool.default.name
      path = "/"
    }
  }

  device {
    name = "eth0"
    type = "nic"

    properties = {
      network = incus_network.incusbr0.name
    }
  }
}
