resource "incus_instance" "guest" {
  for_each = var.guests

  name    = each.key
  project = incus_project.user.name
  type    = "container"
  image   = each.value.image

  lifecycle {
    precondition {
      condition = try(
        cidrcontains(var.network_ipv4, each.value.ipv4) &&
        each.value.ipv4 != split("/", var.network_ipv4)[0],
        false,
      )
      error_message = "${each.key}.ipv4 must be inside network_ipv4 and must not be the bridge address."
    }
  }

  profiles = [
    incus_profile.default.name
  ]

  config = {
    "boot.autostart"          = "true"
    "security.nesting"        = "true"
    "security.idmap.isolated" = "true"
    "limits.cpu.allowance"    = each.value.cpu_allowance
    "limits.memory"           = each.value.memory
  }

  device {
    name = "root"
    type = "disk"

    properties = {
      pool = incus_storage_pool.default.name
      path = "/"
      size = each.value.disk_size
    }
  }

  device {
    name = "eth0"
    type = "nic"

    # Incus 7.3でもIPv4 filteringを有効にするとDHCP OFFERを受信できないため、修正されるまでMAC filteringとACLを使う。
    properties = {
      network                                = incus_network.incusbr0.name
      "ipv4.address"                         = each.value.ipv4
      "security.mac_filtering"               = "true"
      "security.acls"                        = incus_network_acl.guest[each.key].name
      "security.acls.default.ingress.action" = "reject"
      "security.acls.default.egress.action"  = "allow"
    }
  }
}
