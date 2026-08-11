#!/usr/bin/env bash
set -euo pipefail

repo_root=${INFRA_ROOT:-$PWD}
tofu_dir="$repo_root/tofu"
host=$(uname -n)
host=${host%%.*}
tfvars="hosts/$host.tfvars"

usage() {
  cat <<'EOF'
Usage:
  infra plan
  infra deploy
  infra deploy-guests [guest ...]

Commands:
  plan            Initialize, validate, and plan the OpenTofu configuration.
  deploy          Apply OpenTofu, then bootstrap or update every guest.
  deploy-guests   Bootstrap or update guests without changing OpenTofu.

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

require_tfvars() {
  [[ -f "$tofu_dir/$tfvars" ]] || fail "tfvars file not found: $tofu_dir/$tfvars"
}

tofu_init_validate() {
  tofu -chdir="$tofu_dir" init
  tofu -chdir="$tofu_dir" validate
}

tofu_plan() {
  (($# == 0)) || fail "plan takes no arguments"
  require_tfvars
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

deploy_guest() {
  local guest=$1

  echo "Waiting for $guest..."
  wait_for_guest "$guest" || fail "timed out waiting for $guest"

  if incus exec "$guest" -- \
    systemctl is-enabled --quiet nixos-upgrade.timer; then
    echo "Updating $guest..."
    incus exec "$guest" -- systemctl start nixos-upgrade.service
  else
    echo "Bootstrapping $guest..."
    incus exec "$guest" -- \
      nixos-rebuild switch \
      --refresh \
      --option experimental-features "nix-command flakes" \
      --flake "github:s3-odara/infra#$guest"
  fi

  echo "Deployed $guest"
}

deploy_guests() {
  local -a guests=()
  if (($# > 0)); then
    guests=("$@")
  else
    mapfile -t guests < <(incus list --format csv --columns n)
  fi

  ((${#guests[@]} > 0)) || fail "no guests found"

  local guest
  for guest in "${guests[@]}"; do
    if [[ ! $guest =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
      ((${#guest} > 63)); then
      fail "invalid guest name: $guest"
    fi
    incus info "$guest" >/dev/null || fail "guest not found: $guest"
    deploy_guest "$guest"
  done
}

deploy_all() {
  (($# == 0)) || fail "deploy takes no arguments"
  require_tfvars
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
