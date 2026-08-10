network_ipv4 = "10.77.1.1/24"
public_ipv4  = "203.0.113.10"

guests = {
  knot = {
    image  = "images:nixos/unstable"
    ipv4   = "10.77.1.11"
    cpu    = 1
    memory = "512MiB"

    public_ports = [
      {
        protocol = "tcp"
        port     = 53
      },
      {
        protocol = "udp"
        port     = 53
      },
    ]
  }

  prosody = {
    image  = "images:nixos/unstable"
    ipv4   = "10.77.1.10"
    cpu    = 1
    memory = "1GiB"

    public_ports = [
      {
        protocol = "tcp"
        port     = 5222
      },
      {
        protocol = "tcp"
        port     = 5269
      },
    ]
  }
}
