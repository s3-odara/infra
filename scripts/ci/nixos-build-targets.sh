#!/usr/bin/env bash
set -euo pipefail

(($# == 1)) || {
  echo "Usage: nixos-build-targets.sh HOST" >&2
  exit 2
}
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
host=$1
guest_list=$("$repo_root/scripts/guest-list.sh" "$host")

# Do not emit the host until guest enumeration has completed successfully.
printf 'path:.#nixosConfigurations.%s.config.system.build.toplevel\n' "$host"
if [[ -n $guest_list ]]; then
  while IFS= read -r guest; do
    printf 'path:.#nixosConfigurations.%s.config.system.build.toplevel\n' "$guest"
  done <<<"$guest_list"
fi
