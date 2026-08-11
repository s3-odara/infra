#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: deploy-host.sh [--reboot] <me@target>

Irregular fallback: build incus-01 locally, create a complete unsigned file
binary cache, upload the whole cache, and register a next-boot generation.
Normal operation is scripts/update-host.sh on the VPS itself.

The temporary cache is large (the closure is approximately 2.9 GiB). This
script checks for 4 GiB locally before creating it and checks the actual cache
size plus a 512 MiB margin on remote /var/tmp before upload. No signing key,
trusted user, or trusted public key is required.

The target host key must already be in known_hosts. SSH enforces
StrictHostKeyChecking=yes and BatchMode=yes.
EOF
}

fail() {
  echo "deploy-host: $*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

reboot=false
while (($# > 0)); do
  case $1 in
  --reboot)
    reboot=true
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  --*) fail "unknown option: $1" ;;
  *) break ;;
  esac
done
(($# == 1)) || {
  usage >&2
  exit 1
}

target=$1
if [[ ! $target =~ ^me@([A-Za-z0-9][A-Za-z0-9.-]*)$ ]]; then
  fail "target must have the form me@hostname-or-ip (without SSH options)"
fi
host=${BASH_REMATCH[1]}
[[ $host != *..* && $host != *. && $host != *.-* && $host != *-. ]] ||
  fail "invalid target host: $host"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
[[ -f "$repo_root/flake.nix" ]] || fail "flake.nix not found in repository root: $repo_root"

ssh_options=(-o StrictHostKeyChecking=yes -o BatchMode=yes)
local_tmp=
remote_dir=
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n $remote_dir ]]; then
    # remote_dir is accepted only after the fixed mktemp prefix is validated.
    # shellcheck disable=SC2029
    ssh "${ssh_options[@]}" "$target" "rm -rf -- '$remote_dir'" >/dev/null 2>&1 ||
      echo "deploy-host: WARNING: could not remove remote temporary cache: $remote_dir" >&2
  fi
  [[ -z $local_tmp ]] || rm -rf -- "$local_tmp"
  exit "$status"
}
trap cleanup EXIT

installable="path:$repo_root#nixosConfigurations.incus-01.config.system.build.toplevel"
log "Building the incus-01 system locally"
build_output=$(nix build --no-link --print-out-paths "$installable")
mapfile -t build_outputs <<<"$build_output"
((${#build_outputs[@]} == 1)) || fail "nix build did not return exactly one output path"
system=${build_outputs[0]}
[[ $system =~ ^/nix/store/[0-9a-z]{32}-nixos-system-incus-01-[^/[:space:]]+$ ]] ||
  fail "nix build returned an unexpected system path: $system"
[[ -d $system && -x $system/bin/switch-to-configuration ]] ||
  fail "built system is missing switch-to-configuration: $system"
printf 'Built: %s\n' "$system"

# File caches duplicate the closure rather than sending only remote-missing paths.
# 4 GiB is a deliberately simple conservative preflight for the ~2.9 GiB closure.
tmp_parent=${TMPDIR:-/tmp}
local_free=$(df -PB1 "$tmp_parent" | awk 'NR == 2 { print $4 }')
[[ $local_free =~ ^[0-9]+$ ]] || fail "could not determine local free space for $tmp_parent"
local_required=$((4 * 1024 * 1024 * 1024))
((local_free >= local_required)) ||
  fail "at least 4 GiB free is required under $tmp_parent for the complete temporary cache"

local_tmp=$(mktemp -d "$tmp_parent/deploy-host.XXXXXXXX")
cache_dir=$local_tmp/cache
mkdir -- "$cache_dir"
log "Creating a complete unsigned file cache (approximately 2.9 GiB)"
nix copy --to "file://$cache_dir" "$system"
cache_bytes=$(du -sb -- "$cache_dir" | awk '{ print $1 }')
[[ $cache_bytes =~ ^[0-9]+$ && $cache_bytes -gt 0 ]] || fail "could not determine cache size"
printf 'Complete cache size: %s bytes\n' "$cache_bytes"

log "Checking NixOS target and creating a user-owned remote temporary directory"
remote_dir=$(ssh "${ssh_options[@]}" "$target" \
  "grep -qx 'ID=nixos' /etc/os-release && [ \"\$(hostname -s)\" = incus-01 ] && command -v doas >/dev/null && mktemp -d /var/tmp/infra-cache.XXXXXXXX") ||
  fail "remote preflight failed (SSH/known_hosts, NixOS hostname, doas, or /var/tmp)"
[[ $remote_dir =~ ^/var/tmp/infra-cache\.[A-Za-z0-9]+$ ]] || {
  remote_dir=
  fail "remote mktemp returned an unsafe path"
}
remote_cache=$remote_dir/cache

remote_free=$(ssh "${ssh_options[@]}" "$target" "df -PB1 /var/tmp | awk 'NR == 2 { print \$4 }'") ||
  fail "could not determine remote /var/tmp free space"
[[ $remote_free =~ ^[0-9]+$ ]] || fail "remote /var/tmp returned an invalid free-space value"
margin=$((512 * 1024 * 1024))
required=$((cache_bytes + margin))
((remote_free >= required)) ||
  fail "remote /var/tmp has $remote_free bytes free; $required bytes are required (cache plus margin); no disk changes were made"

log "Uploading the complete cache to $target:$remote_dir"
scp -r "${ssh_options[@]}" -- "$cache_dir" "$target:$remote_dir/"

log "Importing the unsigned cache as root (irregular fallback only)"
# Only text commands use the TTY, allowing doas to prompt. Cache bytes traveled via scp.
# shellcheck disable=SC2029
ssh -t "${ssh_options[@]}" "$target" \
  "doas nix copy --no-check-sigs --from 'file://$remote_cache' '$system'" ||
  fail "root cache import failed"

# Drop the large cache before activation. The EXIT trap retries cleanup on all failures.
# shellcheck disable=SC2029
if ssh "${ssh_options[@]}" "$target" "rm -rf -- '$remote_dir'"; then
  remote_dir=
else
  fail "cache imported, but remote temporary cache cleanup failed"
fi

log "Registering the remote next-boot generation"
activation_command="previous=\$(readlink -e /nix/var/nix/profiles/system) || { echo 'deploy-host: cannot resolve current system profile' >&2; exit 1; }
case \$previous in /nix/store/*) ;; *) echo 'deploy-host: unexpected current profile target' >&2; exit 1 ;; esac
if ! doas nix-env --profile /nix/var/nix/profiles/system --set '$system'; then
  echo 'deploy-host: profile set failed; previous pointer is unchanged' >&2
  exit 1
fi
if doas '$system/bin/switch-to-configuration' boot; then
  exit 0
fi
echo 'deploy-host: boot activation failed; restoring only the previous profile pointer' >&2
if doas nix-env --profile /nix/var/nix/profiles/system --set \"\$previous\"; then
  echo 'deploy-host: previous profile restored; old Nix/systemd-boot generations remain available' >&2
else
  echo 'deploy-host: WARNING: failed to restore the previous profile pointer' >&2
fi
exit 1"
# shellcheck disable=SC2029
ssh -t "${ssh_options[@]}" "$target" "$activation_command" ||
  fail "activation failed; no reboot was attempted"

cat <<EOF

Fallback deployment prepared successfully for $target.
The running system was not switched or rebooted. Old Nix generations and
systemd-boot entries remain available; select an older entry at boot to roll back.
EOF

if [[ $reboot == false ]]; then
  exit 0
fi
[[ -t 0 ]] || fail "refusing to reboot without interactive stdin; reboot $target manually when ready"
read -r -p "Type 'reboot' to reboot $target now: " confirmation
[[ $confirmation == reboot ]] || fail "reboot cancelled"
log "Rebooting $target"
ssh -t "${ssh_options[@]}" "$target" 'doas systemctl reboot'
