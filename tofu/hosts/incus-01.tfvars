network_ipv4 = "10.77.1.1/24"
public_ipv4  = "167.179.72.51"

guests = {
  nsd = {
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
        port     = 5269
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
