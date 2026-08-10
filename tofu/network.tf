resource "incus_network" "incusbr0" {
  name = "incusbr0"
  type = "bridge"

  description = "Managed bridge for service containers"

  config = {
    "ipv4.address"  = var.network_ipv4
    "ipv4.nat"      = "true"
    "ipv4.dhcp"     = "true"
    "ipv4.firewall" = "true"

    "ipv6.address" = "none"
  }
}
