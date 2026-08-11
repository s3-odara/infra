#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: update-host.sh [--pull] [--reboot]

Build the current incus-01 checkout on the VPS and register the result as the
next-boot generation. The checkout and flake.lock are not updated by default.

  --pull    Fast-forward the current branch from origin before building
  --reboot  After success, interactively require the exact word "reboot"
  -h, --help

Run this script as the normal user on incus-01, not as root. It does not copy a
closure, change persistent Nix job settings, or handle any secrets.
EOF
}

fail() {
  echo "update-host: $*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

pull=false
reboot=false
while (($# > 0)); do
  case $1 in
  --pull) pull=true ;;
  --reboot) reboot=true ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    fail "unknown argument: $1"
    ;;
  esac
  shift
done

((EUID != 0)) || fail "refusing to run as root (git and nix build must run as the normal user)"

grep -qx 'ID=nixos' /etc/os-release || fail "this script must run on NixOS"
[[ $(hostname -s) == incus-01 ]] || fail "this script must run on host incus-01"
command -v doas >/dev/null || fail "doas is required"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
[[ -f "$repo_root/flake.nix" ]] || fail "flake.nix not found in repository root: $repo_root"

if [[ $pull == true ]]; then
  log "Fast-forwarding the current branch from origin"
  [[ -z $(git -C "$repo_root" status --porcelain) ]] ||
    fail "--pull requires a clean worktree (including no untracked files)"
  branch=$(git -C "$repo_root" symbolic-ref --quiet --short HEAD) ||
    fail "--pull is not allowed from a detached HEAD"
  git check-ref-format --branch "$branch" >/dev/null || fail "current branch name is invalid"
  git -C "$repo_root" fetch origin "$branch"
  git -C "$repo_root" merge --ff-only "origin/$branch"
fi

installable="path:$repo_root#nixosConfigurations.incus-01.config.system.build.toplevel"
log "Building the current incus-01 checkout with one job and one core"
build_output=$(nix build --no-link --print-out-paths \
  --option max-jobs 1 --option cores 1 "$installable")
mapfile -t build_outputs <<<"$build_output"
((${#build_outputs[@]} == 1)) || fail "nix build did not return exactly one output path"
system=${build_outputs[0]}
[[ $system =~ ^/nix/store/[0-9a-z]{32}-nixos-system-incus-01-[^/[:space:]]+$ ]] ||
  fail "nix build returned an unexpected system path: $system"
[[ -d $system && -x $system/bin/switch-to-configuration ]] ||
  fail "built system is missing switch-to-configuration: $system"
printf 'Built: %s\n' "$system"

previous=$(readlink -e /nix/var/nix/profiles/system) ||
  fail "cannot resolve the current system profile; activation was not attempted"
[[ $previous == /nix/store/* ]] ||
  fail "current system profile has an unexpected target; activation was not attempted"

log "Registering the next-boot generation"
if ! doas nix-env --profile /nix/var/nix/profiles/system --set "$system"; then
  fail "failed to set the system profile; the previous pointer is unchanged"
fi
if ! doas "$system/bin/switch-to-configuration" boot; then
  echo "update-host: boot activation failed; restoring only the previous profile pointer" >&2
  if doas nix-env --profile /nix/var/nix/profiles/system --set "$previous"; then
    echo "update-host: previous profile restored; old Nix/systemd-boot generations remain available" >&2
  else
    echo "update-host: WARNING: failed to restore the previous profile pointer" >&2
  fi
  fail "boot activation failed; no reboot was attempted"
fi

cat <<EOF

Next-boot generation registered successfully: $system
The running system was not switched or rebooted. Old Nix generations and
systemd-boot entries remain available; select an older entry at boot to roll back.
EOF

if [[ $reboot == false ]]; then
  exit 0
fi
[[ -t 0 ]] || fail "refusing to reboot without interactive stdin; reboot manually when ready"
read -r -p "Type 'reboot' to reboot incus-01 now: " confirmation
[[ $confirmation == reboot ]] || fail "reboot cancelled"
log "Rebooting incus-01"
doas systemctl reboot
