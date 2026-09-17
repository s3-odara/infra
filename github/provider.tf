terraform {
  required_version = ">= 1.8.0"

  required_providers {
    github = {
      source = "integrations/github"
    }
  }
}

variable "github_app_pem_file" {
  description = "PEM contents of the infra-tofu GitHub App private key"
  type        = string
  sensitive   = true
}

variable "update_github_app_id" {
  description = "Public App ID of the dedicated dependency-update GitHub App"
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+$", var.update_github_app_id))
    error_message = "Set update_github_app_id to the manually registered update App ID."
  }
}

provider "github" {
  owner = "s3-odara"

  app_auth {
    id              = "4944152"
    installation_id = "161706878"
    pem_file        = var.github_app_pem_file
  }
}
