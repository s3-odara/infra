#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
tofu_dir="$repo_root/tofu"
host=$(uname -n)
host=${host%%.*}
tfvars="hosts/$host.tfvars"

usage() {
  echo "Usage: tofu.sh <plan|apply>"
}

fail() {
  echo "tofu: $*" >&2
  exit 1
}

(($# == 1)) || {
  usage >&2
  exit 1
}
command=$1
case $command in plan | apply) ;; -h | --help) usage; exit ;; *) fail "unknown command: $command" ;; esac

[[ -f "$tofu_dir/$tfvars" ]] || fail "tfvars file not found: $tofu_dir/$tfvars"

if [[ ${INFRA_TOFU_TOOLS:-} != 1 ]]; then
  exec nix shell "path:$repo_root#opentofu" \
    -c env INFRA_TOFU_TOOLS=1 "$script_dir/tofu.sh" "$command"
fi

tofu_bin=$(command -v tofu)
doas "$tofu_bin" -chdir="$tofu_dir" init
doas "$tofu_bin" -chdir="$tofu_dir" validate
doas "$tofu_bin" -chdir="$tofu_dir" "$command" -var-file="$tfvars"
