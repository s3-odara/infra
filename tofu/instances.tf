resource "incus_instance" "guest" {
  for_each = var.guests

  name    = each.key
  project = incus_project.user.name
  type  = "container"
  image = each.value.image

  profiles = [
    incus_profile.default.name
  ]

  config = {
    "boot.autostart"   = "true"
    "security.nesting" = "true"
    "security.idmap.isolated" = "true"
    "limits.cpu"    = tostring(each.value.cpu)
    "limits.memory" = each.value.memory
  }

  device {
    name = "eth0"
    type = "nic"

    properties = {
      network = incus_network.incusbr0.name
      "ipv4.address"            = each.value.ipv4
      "security.ipv4_filtering" = "true"
      "security.acls" = incus_network_acl.guest[each.key].name
      "security.acls.default.ingress.action" = "reject"
      "security.acls.default.egress.action"  = "allow"
    }
  }
}
