#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
tofu_dir="$repo_root/tofu"
host=$(uname -n)
host=${host%%.*}
tfvars="hosts/$host.tfvars"

fail() {
  echo "tofu: $*" >&2
  exit 1
}

(($# == 0)) || fail "this command does not accept arguments"
[[ -f "$tofu_dir/$tfvars" ]] || fail "tfvars file not found: $tofu_dir/$tfvars"

if [[ ${INFRA_TOFU_TOOLS:-} != 1 ]]; then
  exec nix shell "path:$repo_root#opentofu" \
    -c env INFRA_TOFU_TOOLS=1 "$script_dir/tofu.sh"
fi

tofu_bin=$(command -v tofu)
doas "$tofu_bin" -chdir="$tofu_dir" init
doas "$tofu_bin" -chdir="$tofu_dir" apply -var-file="$tfvars"
