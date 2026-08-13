network_ipv4 = "10.77.2.1/24"
public_ipv4  = "133.117.77.64"

guests = {
  nsd = {
    image         = "images:nixos/unstable"
    ipv4          = "10.77.2.11"
    cpu_allowance = "100ms/100ms"
    memory        = "2GiB"
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
  }

  prosody = {
    image         = "images:nixos/unstable"
    ipv4          = "10.77.2.10"
    cpu_allowance = "100ms/100ms"
    memory        = "2GiB"
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
        port     = 5269
      },
    ]
    private_ports = []
  }

  wireguard = {
    image         = "images:nixos/unstable"
    ipv4          = "10.77.2.12"
    cpu_allowance = "100ms/100ms"
    memory        = "2GiB"
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
