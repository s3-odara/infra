#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
host=$(uname -n)
host=${host%%.*}

fail() {
  echo "guests: $*" >&2
  exit 1
}

wait_for_guest() {
  local guest=$1
  local _
  for _ in {1..60}; do
    incus exec "$guest" -- true >/dev/null 2>&1 && return
    sleep 2
  done
  fail "timed out waiting for $guest"
}

copy_secrets() {
  local guest=$1
  local ciphertext="$main_source/secrets/guests/$host/$guest/secrets.sops.yaml"
  [[ -e $ciphertext ]] || return 0
  [[ -f $ciphertext ]] || fail "encrypted secrets path is not a file for $guest"
  incus exec "$guest" -- sh -c "$(<"$script_dir/install-guest-ciphertext.sh")" \
    <"$ciphertext" || fail "failed to copy encrypted secrets into $guest"
}

if (($# == 0)); then
  if ! guest_list=$(incus list --format csv --columns n); then
    fail "could not enumerate Incus guests"
  fi
  [[ -n $guest_list ]] || fail "no guests found"
  mapfile -t guests <<<"$guest_list"
else
  guests=("$@")
fi
((${#guests[@]} > 0)) || fail "no guests found"

metadata=$(nix flake metadata --refresh --no-update-lock-file --json \
  github:s3-odara/infra/main)
main_commit=$(jq -er '.locked.rev | select(type == "string")' <<<"$metadata")
main_source=$(jq -er '.path | select(type == "string")' <<<"$metadata")
[[ $main_commit =~ ^[0-9a-f]{40}$ ]] || fail "could not resolve GitHub main commit"
[[ $main_source == /nix/store/* && -d $main_source ]] ||
  fail "GitHub main snapshot path is invalid"
echo "Using GitHub main commit $main_commit from $main_source for every guest"

for guest in "${guests[@]}"; do
  [[ $guest =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || fail "invalid guest name: $guest"
  incus info "$guest" >/dev/null || fail "guest not found: $guest"
  echo "Waiting for $guest..."
  wait_for_guest "$guest"
  copy_secrets "$guest"
  echo "Updating $guest..."
  incus exec "$guest" -- nixos-rebuild switch \
    --option experimental-features "nix-command flakes" \
    --flake "github:s3-odara/infra/$main_commit#$guest"
  echo "Updated $guest"
done
