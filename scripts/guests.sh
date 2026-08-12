#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
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
  local source="$repo_root/secrets/guests/$host/$guest/secrets.sops.yaml"
  local guest_script

  [[ -f $source ]] || return
  guest_script=$(cat <<'EOF'
set -eu
directory=/var/lib/sops-nix
destination="$directory/secrets.sops.yaml"
install -d -o root -g root -m 0700 "$directory"
temporary=$(mktemp "$directory/.secrets.sops.yaml.XXXXXX")
trap 'rm -f "$temporary"' EXIT
cat >"$temporary"
test -s "$temporary"
chown root:root "$temporary"
chmod 0600 "$temporary"
mv -f "$temporary" "$destination"
trap - EXIT
EOF
)
  incus exec "$guest" -- sh -c "$guest_script" <"$source" ||
    fail "failed to copy encrypted secrets into $guest"
}

update_guest() {
  local guest=$1

  echo "Waiting for $guest..."
  wait_for_guest "$guest"
  copy_secrets "$guest"

  if incus exec "$guest" -- \
    systemctl is-enabled --quiet nixos-upgrade.timer; then
    echo "Updating $guest..."
    incus exec "$guest" -- systemctl start --wait nixos-upgrade.service
  else
    echo "Bootstrapping $guest..."
    incus exec "$guest" -- nixos-rebuild switch \
      --refresh \
      --option experimental-features "nix-command flakes" \
      --flake "github:s3-odara/infra#$guest"
  fi
  echo "Updated $guest"
}

(($# > 0)) || mapfile -t guests < <(incus list --format csv --columns n)
(($# == 0)) || guests=("$@")
((${#guests[@]} > 0)) || fail "no guests found"

for guest in "${guests[@]}"; do
  incus info "$guest" >/dev/null || fail "guest not found: $guest"
  update_guest "$guest"
done
