#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "install-host: $*" >&2
  exit 1
}

(($# == 2)) || fail "usage: $0 <nixos-configuration> <user@target-address>"

configuration=$1
target=$2

if [[ ! $configuration =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
  ((${#configuration} > 63)); then
  fail "configuration must use at most 63 lowercase letters, digits, and internal hyphens"
fi

[[ $target == *@* ]] || fail "target must have the form user@target-address"

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

[[ -f "$repo_root/hosts/$configuration/configuration.nix" ]] ||
  fail "host configuration not found: $configuration"

if [[ -d /dev/shm && -w /dev/shm ]]; then
  extra_files=$(mktemp -d /dev/shm/nixos-extra-files.XXXXXXXXXX)
else
  extra_files=$(mktemp -d)
fi
trap 'rm -rf -- "$extra_files"' EXIT

password_hash="$extra_files/etc/nixos-secrets/me-password-hash"
install -d -m 700 "$(dirname -- "$password_hash")"

echo "Enter the password that the me account will use for doas."
umask 077
nix shell "path:$repo_root#mkpasswd" -c mkpasswd -m yescrypt >"$password_hash"
[[ -s $password_hash ]] || fail "password hash generation failed"
chmod 600 "$password_hash"

echo "WARNING: nixos-anywhere will repartition and overwrite $target."
read -r -p "Type '$configuration' to continue: " confirmation
[[ $confirmation == "$configuration" ]] || fail "installation cancelled"

nix run "path:$repo_root#nixos-anywhere" -- \
  --flake "path:$repo_root#$configuration" \
  --target-host "$target" \
  --extra-files "$extra_files"

echo
echo "Installation finished. Log in with: ssh me@${target#*@}"
echo "Copy or clone this repository onto the host, then run: just deploy-guests"
