resource "incus_network_acl" "guest" {
  for_each = var.guests

  project = incus_project.user.name
  name    = each.key

  # Provider reads an empty rule set back as null.
  ingress = length(each.value.public_ports) + length(each.value.private_ports) > 0 ? concat(
    [
      for port in each.value.public_ports : {
        action           = "allow"
        protocol         = port.protocol
        destination_port = port.port
        state            = "enabled"
      }
    ],
    [
      for port in each.value.private_ports : {
        action           = "allow"
        protocol         = port.protocol
        source           = port.source == "network" ? cidrsubnet(var.network_ipv4, 0, 0) : port.source
        destination_port = port.port
        state            = "enabled"
      }
    ],
  ) : null

  # Bridge ACL egress cannot use nftables reject.
  egress = length(each.value.denied_egress) > 0 ? [
    for destination in each.value.denied_egress : {
      action      = "drop"
      destination = destination
      state       = "enabled"
    }
  ] : null
}
