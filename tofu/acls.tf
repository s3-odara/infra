resource "incus_network_acl" "guest" {
  for_each = var.guests

  project = incus_project.user.name
  name    = each.key

  ingress = [
    for port in each.value.public_ports : {
      action           = "allow"
      protocol         = port.protocol
      destination_port = tostring(port.port)
      state            = "enabled"
    }
  ]
}
