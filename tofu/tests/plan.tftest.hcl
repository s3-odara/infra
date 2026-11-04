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
}
