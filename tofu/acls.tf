resource "incus_network_acl" "guest" {
  for_each = var.guests

  project = incus_project.user.name
  name    = each.key

  ingress = concat(
    [
      for port in each.value.public_ports : {
        action           = "allow"
        protocol         = port.protocol
        destination_port = tostring(port.port)
        state            = "enabled"
      }
    ],
    [
      for port in each.value.private_ports : {
        action           = "allow"
        protocol         = port.protocol
        source           = coalesce(port.source, cidrsubnet(var.network_ipv4, 0, 0))
        destination_port = tostring(port.port)
        state            = "enabled"
      }
    ],
  )
}
