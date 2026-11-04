network_ipv4 = "10.77.1.1/24"
public_ipv4  = "167.179.72.51"

guests = {
  knot = {
    image         = "images:nixos/unstable"
    ipv4          = "10.77.1.11"
    cpu_allowance = "100ms/100ms"
    memory        = "512MiB"
    disk_size     = "10GiB"

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
    private_ports = []
    # Authoritative DNS needs no new connections to other bridge guests.
    denied_egress = [
      "10.77.1.0",
      "10.77.1.2-10.77.1.255",
    ]
  }

  prosody = {
    image         = "images:nixos/unstable"
    ipv4          = "10.77.1.10"
    cpu_allowance = "100ms/100ms"
    memory        = "1GiB"
    disk_size     = "10GiB"

    public_ports = [
      {
        protocol = "tcp"
        port     = 80
      },
      {
        protocol = "tcp"
        port     = 443
      },
      {
        protocol = "tcp"
        port     = 5222
      },
      {
        protocol = "tcp"
        port     = 5223
      },
      {
        protocol = "tcp"
        port     = 5269
      },
      {
        protocol = "tcp"
        port     = 5270
      },
    ]
    private_ports = []
  }

  wireguard = {
    image         = "images:nixos/unstable"
    ipv4          = "10.77.1.12"
    cpu_allowance = "100ms/100ms"
    memory        = "512MiB"
    disk_size     = "10GiB"

    public_ports = [
      {
        protocol = "udp"
        port     = 443
      },
    ]
    private_ports = []
  }
}
