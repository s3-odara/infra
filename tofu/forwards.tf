locals {
  public_ports = flatten([
    for guest_name, guest in var.guests : [
      for port in guest.public_ports : {
        guest          = guest_name
        protocol       = port.protocol
        port           = port.port
        target_address = guest.ipv4
      }
    ]
  ])
}

resource "incus_network_forward" "public" {
  project        = "default"
  network        = incus_network.incusbr0.name
  listen_address = var.public_ipv4

  ports = [
    for port in local.public_ports : {
      description    = port.guest
      protocol       = port.protocol
      listen_port    = tostring(port.port)
      target_address = port.target_address
      target_port    = tostring(port.port)
    }
  ]
}
