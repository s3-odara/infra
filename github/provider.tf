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

provider "github" {
  owner = "s3-odara"

  app_auth {
    id              = "4944152"
    installation_id = "161706878"
    pem_file        = var.github_app_pem_file
  }
}
