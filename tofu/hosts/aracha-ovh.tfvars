network_ipv4 = "10.77.3.1/24"
public_ipv4  = "15.235.184.173"

guests = {
  nsd = {
    image         = "images:nixos/unstable"
    ipv4          = "10.77.3.11"
    cpu_allowance = "100ms/100ms"
    memory        = "4GiB"
    disk_size     = "5GiB"

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
    ipv4          = "10.77.3.10"
    cpu_allowance = "100ms/100ms"
    memory        = "4GiB"
    disk_size     = "10GiB"

    public_ports = [
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
    private_ports = [
      {
        protocol = "tcp"
        port     = 80
        source   = "10.77.3.13/32"
      },
      {
        protocol = "tcp"
        port     = 443
        source   = "10.77.3.13/32"
      },
    ]
    denied_egress = [
      "10.77.3.0",
      "10.77.3.2-10.77.3.255",
    ]
  }

  nginx = {
    image         = "images:nixos/unstable"
    ipv4          = "10.77.3.13"
    cpu_allowance = "100ms/100ms"
    memory        = "2GiB"
    disk_size     = "5GiB"

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
        protocol = "udp"
        port     = 443
      },
    ]
    private_ports = []
    denied_egress = [
      "10.77.3.0",
      "10.77.3.2-10.77.3.9",
      "10.77.3.11-10.77.3.13",
      "10.77.3.17-10.77.3.255",
    ]
  }

  tuwunel = {
    image         = "images:nixos/unstable"
    ipv4          = "10.77.3.14"
    cpu_allowance = "100ms/100ms"
    memory        = "4GiB"
    disk_size     = "20GiB"

    public_ports = []
    private_ports = [
      {
        protocol = "tcp"
        port     = 8008
        source   = "10.77.3.13/32"
      },
    ]
    denied_egress = [
      "10.77.3.0",
      "10.77.3.2-10.77.3.12",
      "10.77.3.14-10.77.3.255",
    ]
  }

  sygnal = {
    image         = "images:nixos/unstable"
    ipv4          = "10.77.3.16"
    cpu_allowance = "50ms/100ms"
    memory        = "1GiB"
    disk_size     = "5GiB"

    public_ports = []
    private_ports = [
      {
        protocol = "tcp"
        port     = 5000
        source   = "10.77.3.13/32"
      },
    ]
    denied_egress = [
      "10.77.3.0",
      "10.77.3.2-10.77.3.255",
    ]
  }

  rtc = {
    image         = "images:nixos/unstable"
    ipv4          = "10.77.3.15"
    cpu_allowance = "400ms/100ms"
    memory        = "4GiB"
    disk_size     = "10GiB"

    public_ports = [
      {
        protocol = "udp"
        port     = 3478
      },
      {
        protocol = "tcp"
        port     = 3478
      },
      {
        protocol = "tcp"
        port     = 5349
      },
      {
        protocol = "tcp"
        port     = 7881
      },
      {
        protocol = "udp"
        port     = "49160-49200"
      },
      {
        protocol = "udp"
        port     = "50100-50200"
      },
    ]
    private_ports = [
      {
        protocol = "tcp"
        port     = 80
        source   = "10.77.3.13/32"
      },
      {
        protocol = "tcp"
        port     = 7880
        source   = "10.77.3.13/32"
      },
      {
        protocol = "tcp"
        port     = 8081
        source   = "10.77.3.13/32"
      },
    ]
    denied_egress = [
      "10.77.3.0",
      "10.77.3.2-10.77.3.12",
      "10.77.3.14-10.77.3.255",
    ]
  }

}
