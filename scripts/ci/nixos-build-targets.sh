#!/usr/bin/env bash
set -euo pipefail

(($# == 1)) || {
  echo "Usage: nixos-build-targets.sh HOST" >&2
  exit 2
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
tofu_dir=$repo_root/tofu
host=$1

printf 'path:.#nixosConfigurations.%s.config.system.build.toplevel\n' "$host"

tofu -chdir="$tofu_dir" init -backend=false -lockfile=readonly >/dev/null
printf '%s\n' 'jsonencode(keys(var.guests))' |
  tofu -chdir="$tofu_dir" console -var-file="hosts/$host.tfvars" |
  jq -er '
    fromjson[]
    | "path:.#nixosConfigurations.\(.).config.system.build.toplevel"
  '
