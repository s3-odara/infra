import {
  to = github_repository_ruleset.main
  id = "infra:23320051"
}

import {
  to = github_repository_environment.cachix
  id = "infra:cachix"
}

import {
  to = github_repository_environment_deployment_policy.cachix_main
  id = "infra:cachix:59957805"
}

import {
  to = github_actions_repository_permissions.infra
  id = "infra"
}

import {
  to = github_workflow_repository_permissions.infra
  id = "infra"
}

import {
  to = github_actions_variable.cachix_cache_name
  id = "infra:CACHIX_CACHE_NAME"
}

import {
  to = github_actions_variable.cachix_public_key
  id = "infra:CACHIX_PUBLIC_KEY"
}
