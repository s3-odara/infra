variable "network_ipv4" {
  type = string

  validation {
    condition     = can(cidrhost(var.network_ipv4, 0))
    error_message = "network_ipv4 must be a valid network prefix."
  }
}

variable "public_ipv4" {
  type = string

  validation {
    condition     = can(cidrhost("${var.public_ipv4}/0", 0))
    error_message = "public_ipv4 must be a valid IP address without a prefix."
  }
}

variable "guests" {
  type = map(object({
    image         = string
    ipv4          = string
    cpu_allowance = string
    memory        = string
    disk_size     = string

    public_ports = list(object({
      protocol = string
      port     = number
    }))

    private_ports = list(object({
      protocol = string
      port     = number
      source   = string
    }))
  }))

  validation {
    condition = alltrue([
      for name in keys(var.guests) :
      can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", name)) && length(name) <= 63
    ])
    error_message = "Guest names must be lowercase DNS labels of at most 63 characters."
  }

  validation {
    condition = alltrue([
      for guest in values(var.guests) : can(cidrhost("${guest.ipv4}/0", 0))
    ])
    error_message = "Each guest ipv4 must be a valid IP address without a prefix."
  }

  validation {
    condition = length(distinct([
      for guest in values(var.guests) : guest.ipv4
    ])) == length(var.guests)
    error_message = "Guest IP addresses must be unique."
  }

  validation {
    condition = alltrue(flatten([
      for guest in values(var.guests) : concat(
        [for port in guest.public_ports : contains(["tcp", "udp"], port.protocol)],
        [for port in guest.private_ports : contains(["tcp", "udp"], port.protocol)],
      )
    ]))
    error_message = "Port protocols must be tcp or udp."
  }

  validation {
    condition = alltrue(flatten([
      for guest in values(var.guests) : concat(
        [
          for port in guest.public_ports :
          port.port >= 1 && port.port <= 65535 && floor(port.port) == port.port
        ],
        [
          for port in guest.private_ports :
          port.port >= 1 && port.port <= 65535 && floor(port.port) == port.port
        ],
      )
    ]))
    error_message = "Ports must be integers between 1 and 65535."
  }

  validation {
    condition = alltrue(flatten([
      for guest in values(var.guests) : [
        for port in guest.private_ports :
        port.source == "network" || can(cidrhost(port.source, 0))
      ]
    ]))
    error_message = "Private port sources must be \"network\" or a valid network prefix."
  }

  validation {
    condition = length(distinct(flatten([
      for guest in values(var.guests) : [
        for port in guest.public_ports : "${port.protocol}:${port.port}"
      ]
      ]))) == length(flatten([
      for guest in values(var.guests) : guest.public_ports
    ]))
    error_message = "Public protocol and port combinations must be unique."
  }
}
