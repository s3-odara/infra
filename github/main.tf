locals {
  repository = "infra"
}

resource "github_repository_ruleset" "main" {
  name        = "main"
  repository  = local.repository
  target      = "branch"
  enforcement = "active"
  depends_on  = [github_repository_ruleset.main_pr_gate]

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    required_status_checks {
      strict_required_status_checks_policy = false
      do_not_enforce_on_create             = false

      required_check {
        context        = "check"
        integration_id = 15368
      }

      required_check {
        context        = "build closures"
        integration_id = 15368
      }
    }
  }
}

# Only the maintainer can bypass PR requirements; checks remain mandatory.
resource "github_repository_ruleset" "main_pr_gate" {
  name        = "main PR gate"
  repository  = local.repository
  target      = "branch"
  enforcement = "active"

  bypass_actors {
    actor_id    = 76041920
    actor_type  = "User"
    bypass_mode = "always"
  }

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    pull_request {
      dismiss_stale_reviews_on_push   = true
      require_code_owner_review       = true
      required_approving_review_count = 1
    }
  }
}

resource "github_repository_environment" "cachix" {
  repository  = local.repository
  environment = "cachix"

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "cachix_main" {
  repository     = local.repository
  environment    = github_repository_environment.cachix.environment
  branch_pattern = "main"
}

resource "github_actions_repository_permissions" "infra" {
  repository           = local.repository
  enabled              = true
  allowed_actions      = "selected"
  sha_pinning_required = true

  allowed_actions_config {
    github_owned_allowed = true
    patterns_allowed     = []
    verified_allowed     = false
  }
}

resource "github_workflow_repository_permissions" "infra" {
  repository                       = local.repository
  default_workflow_permissions     = "read"
  can_approve_pull_request_reviews = false
}

resource "github_actions_variable" "update_app_client_id" {
  repository    = local.repository
  variable_name = "UPDATE_APP_CLIENT_ID"
  value         = "Iv23liAvhK1jIpXu0kUj"
}

resource "github_actions_variable" "cachix_cache_name" {
  repository    = local.repository
  variable_name = "CACHIX_CACHE_NAME"
  value         = "s3-odara"
}

resource "github_actions_variable" "cachix_public_key" {
  repository    = local.repository
  variable_name = "CACHIX_PUBLIC_KEY"
  value         = "s3-odara.cachix.org-1:eghgfpDCkVI80Zg01X97Q795Y29YPXovtLvB2ZAT1Lg="
}
