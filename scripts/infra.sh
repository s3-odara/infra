#!/usr/bin/env bash
set -euo pipefail

repo_root=${INFRA_ROOT:-$PWD}
tofu_dir="$repo_root/tofu"
default_tfvars=${INFRA_TFVARS:-hosts/incus-01.tfvars}

usage() {
  cat <<'EOF'
Usage:
  infra plan [--tfvars <path>]
  infra deploy [--tfvars <path>]
  infra deploy-guests [guest ...]

Commands:
  plan            Initialize, validate, and plan the OpenTofu configuration.
  deploy          Apply OpenTofu, then deploy every guest configuration.
  deploy-guests   Build and activate guest configurations through incus exec.

Run these commands on the installed Incus host.
EOF
}

fail() {
  echo "infra: $*" >&2
  exit 1
}

require_repo() {
  [[ -f "$repo_root/flake.nix" ]] ||
    fail "run this command from the repository root (or set INFRA_ROOT)"
}

parse_tfvars() {
  local tfvars=$default_tfvars

  while (($# > 0)); do
    case $1 in
    --tfvars)
      (($# >= 2)) || fail "--tfvars requires a path"
      tfvars=$2
      shift 2
      ;;
    *)
      fail "unknown argument: $1"
      ;;
    esac
  done

  [[ -f "$tofu_dir/$tfvars" ]] || fail "tfvars file not found: $tofu_dir/$tfvars"
  printf '%s\n' "$tfvars"
}

tofu_init_validate() {
  tofu -chdir="$tofu_dir" init
  tofu -chdir="$tofu_dir" validate
}

tofu_plan() {
  local tfvars
  tfvars=$(parse_tfvars "$@")
  tofu_init_validate
  doas tofu -chdir="$tofu_dir" plan -var-file="$tfvars"
}

wait_for_guest() {
  local guest=$1
  local _

  for _ in {1..60}; do
    if incus exec "$guest" -- true >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}

rollback_guest() {
  local guest=$1
  local previous=$2

  [[ -n "$previous" ]] || return 1

  echo "Rolling $guest back to $previous..." >&2
  incus exec "$guest" -- \
    nix-env --profile /nix/var/nix/profiles/system --set "$previous"
  incus exec "$guest" -- \
    "$previous/bin/switch-to-configuration" switch
}

deploy_guest() {
  local guest=$1

  echo "Building the $guest configuration..."
  local system
  system=$(nix build --no-link --print-out-paths \
    "$repo_root#nixosConfigurations.$guest.config.system.build.toplevel")

  echo "Waiting for $guest..."
  wait_for_guest "$guest" || fail "timed out waiting for $guest"

  echo "Importing the Nix closure into $guest..."
  local -a closure=()
  mapfile -t closure < <(nix-store --query --requisites "$system")
  nix-store --export "${closure[@]}" |
    incus exec "$guest" -- nix-store --import >/dev/null

  local previous
  previous=$(incus exec "$guest" -- \
    readlink -f /nix/var/nix/profiles/system 2>/dev/null || true)

  incus exec "$guest" -- \
    nix-env --profile /nix/var/nix/profiles/system --set "$system"

  if ! incus exec "$guest" -- \
    "$system/bin/switch-to-configuration" switch; then
    rollback_guest "$guest" "$previous" || true
    fail "activation failed for $guest"
  fi

  if ! incus exec "$guest" -- \
    systemctl is-system-running --wait --quiet; then
    rollback_guest "$guest" "$previous" || true
    fail "system health check failed for $guest"
  fi

  echo "Deployed $guest ($system)"
}

deploy_guests() {
  require_repo
  [[ -d "$tofu_dir" ]] || fail "missing OpenTofu directory: $tofu_dir"

  local -a guests=()
  if (($# > 0)); then
    guests=("$@")
  else
    mapfile -t guests < <(incus list --format csv --columns n)
  fi

  ((${#guests[@]} > 0)) || fail "no guests found"

  local guest
  for guest in "${guests[@]}"; do
    incus info "$guest" >/dev/null || fail "guest not found: $guest"
    deploy_guest "$guest"
  done
}

deploy_all() {
  local tfvars
  tfvars=$(parse_tfvars "$@")
  tofu_init_validate
  doas tofu -chdir="$tofu_dir" apply -var-file="$tfvars"
  deploy_guests
}

main() {
  local command=${1:-}
  [[ -n "$command" ]] || {
    usage
    exit 1
  }
  shift

  case $command in
  plan)
    require_repo
    tofu_plan "$@"
    ;;
  deploy)
    require_repo
    deploy_all "$@"
    ;;
  deploy-guests)
    deploy_guests "$@"
    ;;
  help | -h | --help)
    usage
    ;;
  *)
    fail "unknown command: $command"
    ;;
  esac
}

main "$@"
:q
