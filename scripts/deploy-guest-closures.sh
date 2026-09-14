#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: deploy-guest-closures.sh USER@HOST" >&2
}

fail() {
  echo "deploy-guest-closures: $*" >&2
  exit 1
}

(($# == 1)) || {
  usage
  exit 2
}

host=$1
[[ $host != -* ]] || fail "host must not start with a hyphen"
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
flake="path:$repo_root"

temporary=$(mktemp -d)
ssh_options=(
  -o ControlMaster=auto
  -o ControlPersist=yes
  -o "ControlPath=$temporary/ssh"
)
ssh_remote() {
  ssh "${ssh_options[@]}" "$@"
}
cleanup() {
  ssh_remote -O exit "$host" >/dev/null 2>&1 || true
  rm -rf -- "$temporary"
}
trap cleanup EXIT

configuration=$(ssh_remote -T "$host" hostname -s)
[[ $configuration =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
  fail "remote returned an invalid hostname: $configuration"
var_file="$repo_root/tofu/hosts/$configuration.tfvars"
[[ -f $var_file ]] || fail "host variables not found: $var_file"

guest_list=$(
  nix shell "$flake#opentofu" "$flake#jq" -c sh -eu -c '
    tofu -chdir="$1" init -backend=false -lockfile=readonly >/dev/null
    printf "%s\n" "jsonencode(keys(var.guests))" |
      tofu -chdir="$1" console -var-file="hosts/$2.tfvars" |
      jq -er '\''fromjson[]'\''
  ' sh "$repo_root/tofu" "$configuration"
)
[[ -n $guest_list ]] || fail "no guests found in ${var_file#"$repo_root/"}"
mapfile -t guests <<<"$guest_list"

declare -A outputs
targets=()
for guest in "${guests[@]}"; do
  targets+=("$flake#nixosConfigurations.$guest.config.system.build.toplevel")
done

echo "Checking guests on $host..."
for guest in "${guests[@]}"; do
  ssh_remote -T "$host" "incus info '$guest' >/dev/null"
done

echo "Building all guest configurations..."
nix build --no-link "${targets[@]}"
for guest in "${guests[@]}"; do
  outputs[$guest]=$(nix build --no-link --print-out-paths \
    "$flake#nixosConfigurations.$guest.config.system.build.toplevel")
done

for guest in "${guests[@]}"; do
  closure="$temporary/$guest.closure"
  missing="$temporary/$guest.missing"
  nix-store --query --requisites "${outputs[$guest]}" >"$closure"

  ssh_remote -T "$host" \
    "incus exec -T '$guest' -- xargs -r nix-store --check-validity --print-invalid" \
    <"$closure" >"$missing"

  if [[ ! -s $missing ]]; then
    echo "$guest: closure is already present"
    continue
  fi

  mapfile -t missing_paths <"$missing"
  echo "$guest: transferring ${#missing_paths[@]} missing store paths..."
  nix-store --export "${missing_paths[@]}" |
    ssh_remote -T "$host" "incus exec -T '$guest' -- nix-store --import >/dev/null"
done

for guest in "${guests[@]}"; do
  secret="$repo_root/secrets/guests/$configuration/$guest/secrets.sops.yaml"
  [[ -f $secret ]] || continue
  [[ -s $secret ]] || fail "encrypted secrets file is empty: ${secret#"$repo_root/"}"
  secret_temporary=".secrets.sops.yaml.deploy.$$.$RANDOM"

  echo "$guest: synchronizing encrypted secrets..."
  if ! ssh_remote -T "$host" \
    "incus exec -T '$guest' -- install -d -o root -g root -m 0700 /var/lib/sops-nix &&
     incus file push - '$guest/var/lib/sops-nix/$secret_temporary' --uid 0 --gid 0 --mode 0600 &&
     incus exec -T '$guest' -- mv -f '/var/lib/sops-nix/$secret_temporary' /var/lib/sops-nix/secrets.sops.yaml" \
    <"$secret"; then
    ssh_remote -T "$host" \
      "incus exec -T '$guest' -- rm -f '/var/lib/sops-nix/$secret_temporary'" || true
    fail "failed to synchronize encrypted secrets into $guest"
  fi
done

for guest in "${guests[@]}"; do
  out=${outputs[$guest]}
  echo "$guest: activating $out"
  ssh_remote -T "$host" \
    "incus exec -T '$guest' -- nix-env --profile /nix/var/nix/profiles/system --set '$out' && incus exec -T '$guest' -- '$out/bin/switch-to-configuration' switch"
done
