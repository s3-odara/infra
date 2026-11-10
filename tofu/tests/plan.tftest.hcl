mock_provider "incus" {}

run "plan" {
  command = plan

  assert {
    condition = alltrue([
      for name in keys(var.guests) : contains([
        for rule in incus_network_acl.guest[name].egress : rule.destination
      ], "169.254.0.0/16")
    ])
    error_message = "Every guest must block link-local/metadata egress."
  }

  assert {
    condition = contains([
      for rule in incus_network_acl.guest["knot"].egress : rule.destination
    ], "${cidrhost(var.network_ipv4, 2)}-${cidrhost(var.network_ipv4, -1)}")
    error_message = "Knot must not initiate connections to other bridge guests."
  }

  assert {
    condition = !contains(keys(var.guests), "radicale") || try(
      length(var.guests.radicale.public_ports) == 0 &&
      length(incus_network_acl.guest["radicale"].ingress) == 1 &&
      alltrue([
        for rule in incus_network_acl.guest["radicale"].ingress :
        rule.action == "allow" &&
        rule.protocol == "tcp" &&
        rule.destination_port == "5232" &&
        rule.source == "${var.guests.nginx.ipv4}/32"
      ]),
      false,
    )
    error_message = "Radicale must accept only TCP 5232 from nginx, with no public forwards."
  }

  assert {
    condition = !contains(keys(var.guests), "radicale") || try(
      contains(var.guests.radicale.denied_egress, "${cidrhost(var.network_ipv4, 2)}-${cidrhost(var.network_ipv4, -1)}") &&
      var.guests.radicale.ipv4 == cidrhost(var.network_ipv4, 18) &&
      toset(var.guests.nginx.denied_egress) == toset([
        cidrhost(var.network_ipv4, 0),
        "${cidrhost(var.network_ipv4, 2)}-${cidrhost(var.network_ipv4, 9)}",
        "${cidrhost(var.network_ipv4, 12)}-${cidrhost(var.network_ipv4, 13)}",
        "${cidrhost(var.network_ipv4, 19)}-${cidrhost(var.network_ipv4, -1)}",
      ]),
      false,
    )
    error_message = "Radicale must not initiate bridge connections, and nginx must not block its backend."
  }
}
