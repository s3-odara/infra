#!/usr/bin/env bash
set -euo pipefail

if (($# != 1)) || [[ $1 != *@* ]]; then
  echo "Usage: $0 <user@target-address>" >&2
  exit 1
fi

target=$1
host=${target#*@}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$script_dir/.." && pwd)
bootstrap="$repo_root/bootstrap"
secrets="$bootstrap/etc/nixos-secrets"
password_hash="$secrets/me-password-hash"
nixos_anywhere=${NIXOS_ANYWHERE_FLAKE:-github:nix-community/nixos-anywhere/036bd2423203b1432f36621404289832183cfecd}

if [[ ! -e "$password_hash" ]]; then
  install -d -m 700 "$bootstrap" "$bootstrap/etc" "$secrets"

  temporary=$(mktemp)
  trap 'rm -f "$temporary"' EXIT

  echo "Enter the password that the me account will use for doas."
  umask 077
  nix shell nixpkgs#mkpasswd -c mkpasswd -m yescrypt >"$temporary"
  [[ -s "$temporary" ]] || {
    echo "Password hash generation failed" >&2
    exit 1
  }

  install -m 600 "$temporary" "$password_hash"
  rm -f "$temporary"
  trap - EXIT
  echo "Created $password_hash"
else
  chmod 600 "$password_hash"
  echo "Using existing $password_hash"
fi

echo "Building incus-01 before installation..."
nix build --no-link \
  "$repo_root#nixosConfigurations.incus-01.config.system.build.toplevel"

echo
echo "WARNING: nixos-anywhere will repartition and overwrite $target."
read -r -p "Type 'incus-01' to continue: " confirmation
[[ "$confirmation" == incus-01 ]] || {
  echo "Installation cancelled" >&2
  exit 1
}

nix run "$nixos_anywhere" -- \
  --flake "$repo_root#incus-01" \
  --target-host "$target" \
  --extra-files "$bootstrap"

echo
echo "Installation finished. Log in with: ssh me@$host"
echo "Copy or clone this repository onto the host, then run: nix run .#infra -- deploy"
