#!/usr/bin/env bash
set -euo pipefail

(($# == 1)) || {
  echo "Usage: guest-list.sh HOST" >&2
  exit 2
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
host=$1
[[ $host =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || {
  echo "guest-list: invalid host name: $host" >&2
  exit 1
}
tofu -chdir="$repo_root/tofu" init -backend=false -lockfile=readonly >/dev/null
printf '%s\n' 'jsonencode(keys(var.guests))' |
  tofu -chdir="$repo_root/tofu" console -var-file="hosts/$host.tfvars" |
  jq -er 'fromjson[]'
