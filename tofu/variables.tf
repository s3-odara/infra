variable "network_ipv4" {
  type = string
}

variable "public_ipv4" {
  type = string
}

variable "guests" {
  type = map(object({
    image  = string
    ipv4   = string
    cpu    = number
    memory = string

    public_ports = optional(list(object({
      protocol = string
      port     = number
    })), [])
  }))
}
